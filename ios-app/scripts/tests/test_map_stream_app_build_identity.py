from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "generate_map_stream_app_build_identity.py"
SPEC = importlib.util.spec_from_file_location("map_stream_app_identity", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class MapStreamAppBuildIdentityTests(unittest.TestCase):
    def test_component_changes_when_binary_inputs_or_configuration_change(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "App.swift"
            source.write_text("let value = 1\n", encoding="utf-8")
            inputs = [("App.swift", source)]
            inventory = {"configuration": "Release", "build": "100"}
            first = MODULE.component_sha256(inputs, inventory)
            source.write_text("let value = 2\n", encoding="utf-8")
            changed_source = MODULE.component_sha256(inputs, inventory)
            changed_configuration = MODULE.component_sha256(
                inputs,
                {"configuration": "Debug", "build": "100"},
            )
            self.assertRegex(first, r"^[0-9a-f]{64}$")
            self.assertNotEqual(first, changed_source)
            self.assertNotEqual(changed_source, changed_configuration)


if __name__ == "__main__":
    unittest.main()
