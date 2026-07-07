import json
import tempfile
import unittest
from pathlib import Path

from map_platform.jobs import JobStore, MapJobService
from map_platform.limits import JobLimits
from map_platform.models import Bounds, SourceRegion
from map_platform.sources import SourceIndex, SourceResolutionError


class SourceAndJobTests(unittest.TestCase):
    def setUp(self):
        self.singapore = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            local_path="backend/data/source-pbf/sg.osm.pbf",
        )
        self.germany = SourceRegion(
            id="de",
            provider="test",
            name="Germany",
            url="https://example.invalid/de.osm.pbf",
            bounds=Bounds(5.5, 47.0, 15.5, 55.2),
            local_path="backend/data/source-pbf/de.osm.pbf",
        )

    def test_resolves_smallest_containing_source(self):
        index = SourceIndex([self.germany, self.singapore])

        source = index.resolve_for_bounds(Bounds(103.75, 1.24, 103.93, 1.37))

        self.assertEqual(source.id, "sg")

    def test_rejects_uncovered_bounds(self):
        index = SourceIndex([self.singapore])

        with self.assertRaises(SourceResolutionError):
            index.resolve_for_bounds(Bounds(-122.6, 37.6, -122.3, 37.9))

    def test_dynamic_geofabrik_source_covers_prefilled_nagoya_cutout(self):
        from map_platform.geofabrik_sources import GeofabrikSourceProvider

        with tempfile.TemporaryDirectory() as tmp:
            catalog_path = Path(tmp) / "geofabrik-index-v1.json"
            catalog_path.write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "id": "asia",
                                    "name": "Asia",
                                    "urls": {"pbf": "https://download.geofabrik.de/asia-latest.osm.pbf"},
                                },
                                "geometry": {
                                    "type": "Polygon",
                                    "coordinates": [[[60, -10], [160, -10], [160, 60], [60, 60], [60, -10]]],
                                },
                            },
                            {
                                "type": "Feature",
                                "properties": {
                                    "id": "nearby-region",
                                    "parent": "japan",
                                    "name": "Nearby region with overlapping bounds",
                                    "urls": {"pbf": "https://download.geofabrik.de/asia/japan/nearby-latest.osm.pbf"},
                                },
                                "geometry": {
                                    "type": "Polygon",
                                    "coordinates": [
                                        [[136, 34], [138, 34], [138, 36], [136, 36], [136, 34]],
                                        [[136.5, 34.8], [137.2, 34.8], [137.2, 35.5], [136.5, 35.5], [136.5, 34.8]],
                                    ],
                                },
                            },
                            {
                                "type": "Feature",
                                "properties": {
                                    "id": "japan",
                                    "parent": "asia",
                                    "name": "Japan",
                                    "urls": {"pbf": "https://download.geofabrik.de/asia/japan-latest.osm.pbf"},
                                },
                                "geometry": {
                                    "type": "Polygon",
                                    "coordinates": [[[122, 20], [154.5, 20], [154.5, 46.5], [122, 46.5], [122, 20]]],
                                },
                            },
                        ],
                    }
                )
            )
            provider = GeofabrikSourceProvider(catalog_path.as_uri(), cache_path=Path(tmp) / "cache.json")
            source_index_path = Path(__file__).resolve().parents[1] / "config" / "source-regions.json"
            index = SourceIndex.from_json(source_index_path, fallback_provider=provider)

            source = index.resolve_for_bounds(Bounds(136.75, 35.05, 137.04, 35.29))

        self.assertEqual(source.id, "geofabrik-japan")
        self.assertEqual(source.local_path, "backend/data/source-pbf/geofabrik/japan-latest.osm.pbf")

    def test_create_job_persists_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)))
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "displayName": "Singapore central",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )

            loaded = service.get_job(job.job_id)
            self.assertEqual(loaded.status.value, "queued")
            self.assertEqual(loaded.source_region.id, "sg")
            self.assertEqual(loaded.request["displayName"], "Singapore central")

    def test_create_job_enforces_active_job_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)), limits=JobLimits(max_active_jobs=1))
            service.create_job(
                {
                    "mode": "custom_bbox",
                    "displayName": "Singapore central",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )

            with self.assertRaises(ValueError):
                service.create_job(
                    {
                        "mode": "custom_bbox",
                        "displayName": "Singapore north",
                        "bbox": [103.75, 1.37, 103.93, 1.47],
                    }
                )


if __name__ == "__main__":
    unittest.main()
