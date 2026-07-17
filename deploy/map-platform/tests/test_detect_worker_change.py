from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "detect_worker_change.py"
SPEC = importlib.util.spec_from_file_location("detect_worker_change", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
detect_worker_change = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = detect_worker_change
SPEC.loader.exec_module(detect_worker_change)


class DetectWorkerChangeTests(unittest.TestCase):
    def test_all_declared_worker_roots_are_classified_as_worker_changes(self) -> None:
        for root in detect_worker_change.WORKER_SOURCE_ROOTS:
            with self.subTest(root=root):
                self.assertTrue(detect_worker_change.worker_inputs_changed([root]))
                if "." not in Path(root).name:
                    self.assertTrue(
                        detect_worker_change.worker_inputs_changed([f"{root}/child.py"])
                    )

    def test_control_plane_and_deployment_paths_do_not_move_worker(self) -> None:
        self.assertFalse(
            detect_worker_change.worker_inputs_changed(
                [
                    ".github/workflows/map-platform-image.yml",
                    "config/map-stream-rollout-approvals.json",
                    "config/map-stream-trust.json",
                    "deploy/map-platform/compose.yaml",
                    "backend/README.md",
                    "backend/docker-compose.yml",
                ]
            )
        )

    def test_unknown_git_range_is_conservative(self) -> None:
        self.assertIsNone(
            detect_worker_change.git_changed_paths(
                detect_worker_change.REPO_ROOT,
                "",
                "a" * 40,
            )
        )
        self.assertIsNone(
            detect_worker_change.git_changed_paths(
                detect_worker_change.REPO_ROOT,
                "0" * 40,
                "a" * 40,
            )
        )

    def test_repository_escape_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "outside the repository"):
            detect_worker_change.worker_inputs_changed(["../backend/map_platform/api.py"])


if __name__ == "__main__":
    unittest.main()
