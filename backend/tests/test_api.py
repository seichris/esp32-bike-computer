import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient

from map_platform.api import create_app


class MapJobRunAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo_root = Path(__file__).resolve().parents[2]
        self.environment = patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_REPO_ROOT": str(self.repo_root),
                "MAP_PLATFORM_DATA_ROOT": self.tmp.name,
                "MAP_PLATFORM_SOURCE_INDEX": str(self.repo_root / "backend" / "config" / "source-regions.json"),
                "MAP_PLATFORM_API_TOKEN": "",
                "MAP_PLATFORM_DOWNLOAD_SECRET": "test-secret",
            },
            clear=False,
        )
        self.environment.start()
        self.client = TestClient(create_app())

    def tearDown(self):
        self.client.close()
        self.environment.stop()
        self.tmp.cleanup()

    def create_job(self) -> str:
        response = self.client.post(
            "/v1/map-jobs",
            json={"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]},
        )
        self.assertEqual(response.status_code, 200)
        return response.json()["jobId"]

    def test_run_route_returns_queued_job_result(self):
        job_id = self.create_job()
        result = Mock()
        result.to_dict.return_value = {"jobId": job_id, "status": "ready"}

        with patch("map_platform.api.run_job", return_value=result):
            response = self.client.post(f"/v1/map-jobs/{job_id}/run")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ready")

    def test_run_route_rejects_active_job(self):
        job_id = self.create_job()
        job_path = Path(self.tmp.name) / "jobs" / f"{job_id}.json"
        job = json.loads(job_path.read_text())
        job["status"] = "validating"
        job["workerId"] = "worker-active"
        job_path.write_text(json.dumps(job))

        response = self.client.post(f"/v1/map-jobs/{job_id}/run")

        self.assertEqual(response.status_code, 409)
        self.assertIn("not queued", response.json()["detail"])

    def test_run_route_rejects_cancelled_job(self):
        job_id = self.create_job()
        self.assertEqual(self.client.post(f"/v1/map-jobs/{job_id}/cancel").status_code, 200)

        response = self.client.post(f"/v1/map-jobs/{job_id}/run")

        self.assertEqual(response.status_code, 409)
        self.assertIn("cancelled", response.json()["detail"])

    def test_run_route_returns_not_found_for_missing_job(self):
        response = self.client.post("/v1/map-jobs/missing-job/run")

        self.assertEqual(response.status_code, 404)

    def test_list_jobs_filters_by_client_installation(self):
        first = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-first",
                "clientRequestId": "request-first-123",
            },
        )
        self.assertEqual(first.status_code, 200)
        second = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.76, 1.25, 103.94, 1.38],
                "clientInstallationId": "installation-second",
                "clientRequestId": "request-second-123",
            },
        )
        self.assertEqual(second.status_code, 200)

        response = self.client.get(
            "/v1/map-jobs",
            params={"clientInstallationId": "installation-first"},
        )

        self.assertEqual(response.status_code, 200)
        jobs = response.json()["jobs"]
        self.assertEqual([job["jobId"] for job in jobs], [first.json()["jobId"]])

    def test_job_reads_require_matching_installation(self):
        owned = self.client.post(
            "/v1/map-jobs",
            json={
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-owner",
                "clientRequestId": "request-owner-123",
            },
        ).json()

        missing_filter = self.client.get("/v1/map-jobs")
        matching = self.client.get(
            f"/v1/map-jobs/{owned['jobId']}",
            params={"clientInstallationId": "installation-owner"},
        )
        other = self.client.get(
            f"/v1/map-jobs/{owned['jobId']}",
            params={"clientInstallationId": "installation-other"},
        )
        unscoped = self.client.get(f"/v1/map-jobs/{owned['jobId']}")

        self.assertEqual(missing_filter.status_code, 400)
        self.assertEqual(matching.status_code, 200)
        self.assertEqual(other.status_code, 404)
        self.assertEqual(unscoped.status_code, 404)

    def test_legacy_job_remains_recoverable_by_an_installation(self):
        legacy_job_id = self.create_job()

        response = self.client.get(
            f"/v1/map-jobs/{legacy_job_id}",
            params={"clientInstallationId": "installation-owner"},
        )
        legacy_unscoped = self.client.get(f"/v1/map-jobs/{legacy_job_id}")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(legacy_unscoped.status_code, 200)

    def test_client_metadata_validation_returns_bad_request(self):
        valid = {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
        }
        invalid_payloads = [
            {**valid, "clientInstallationId": "installation-only"},
            {
                **valid,
                "clientInstallationId": "installation-owner",
                "clientRequestId": "request-owner-123",
                "installOnDevice": "yes",
            },
            {
                **valid,
                "clientInstallationId": "bad",
                "clientRequestId": "request-owner-123",
            },
            {
                **valid,
                "clientInstallationId": 123,
                "clientRequestId": "request-owner-123",
            },
        ]

        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                response = self.client.post("/v1/map-jobs", json=payload)
                self.assertEqual(response.status_code, 400)
                self.assertTrue(response.json()["detail"])

        invalid_filter = self.client.get(
            "/v1/map-jobs",
            params={"clientInstallationId": "bad"},
        )
        self.assertEqual(invalid_filter.status_code, 400)


if __name__ == "__main__":
    unittest.main()
