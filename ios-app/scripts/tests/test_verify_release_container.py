import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
IOS_ROOT = REPO_ROOT / "ios-app"
VERIFY_SCRIPT = IOS_ROOT / "scripts" / "verify-release-container.sh"


class ReleaseContainerVerifierTests(unittest.TestCase):
    def make_fixture(self, root: Path) -> Path:
        app = root / "BikeComputer.app"
        watch = app / "Watch" / "BikeComputerWatch.app"
        watch.mkdir(parents=True)

        for path in [app / "BikeComputer", watch / "BikeComputerWatch", watch / "Assets.car"]:
            path.write_bytes(b"fixture")

        shutil.copyfile(
            IOS_ROOT / "BikeComputer" / "BikeComputer" / "PrivacyInfo.xcprivacy",
            app / "PrivacyInfo.xcprivacy",
        )
        shutil.copyfile(
            IOS_ROOT / "BikeComputer" / "BikeComputerWatch" / "PrivacyInfo.xcprivacy",
            watch / "PrivacyInfo.xcprivacy",
        )
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "LetItRide.BikeComputer"}, handle)
        with (watch / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "LetItRide.BikeComputer.watchkitapp",
                    "WKBackgroundModes": ["workout-processing"],
                    "CFBundleIcons": {
                        "CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}
                    },
                },
                handle,
            )
        return app

    def run_verifier(self, app: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(VERIFY_SCRIPT), str(app)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_complete_release_container_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            result = self.run_verifier(app)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_watch_bundle_without_primary_icon_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_fixture(Path(temporary))
            watch_info = app / "Watch" / "BikeComputerWatch.app" / "Info.plist"
            with watch_info.open("rb") as handle:
                payload = plistlib.load(handle)
            del payload["CFBundleIcons"]
            with watch_info.open("wb") as handle:
                plistlib.dump(payload, handle)

            result = self.run_verifier(app)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
