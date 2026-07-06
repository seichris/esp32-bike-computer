#!/usr/bin/env python3
"""Regression tests for XIAO evidence bundle validation."""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import evidence_bundle_check


BOOT_LINES = [
    "Diagnostics: boot free_heap_approx=100000",
    "Diagnostics: reset_reason=0x0 reset_flags=none",
]


def diagnostic(heartbeat: int, uptime_ms: int, **fields: int | str) -> str:
    field_text = " ".join(f"{key}={value}" for key, value in fields.items())
    return (
        f"Diagnostics: runtime heartbeat={heartbeat} uptime_ms={uptime_ms} "
        f"free_heap_approx=99000 {field_text}"
    ).rstrip()


def serial_log(*lines: str) -> str:
    return "\n".join([*BOOT_LINES, *lines, ""])


def write_bundle(root: Path, *, map_lite_log: str | None = None) -> None:
    (root / "hardware-bringup.log").write_text(
        "\n".join(
            [
                "USB: Seeed Studio XIAO nRF52840 mounted at /dev/cu.usbmodem101",
                "EVIDENCE vendor_display=pass",
                "EVIDENCE vendor_touch=pass",
                "EVIDENCE vendor_rtc=pass",
                "EVIDENCE vendor_battery=pass",
                "EVIDENCE vendor_sd=pass",
                "MapLite: SD list path=/ entries=3 truncated=0 error=0",
                "DisplayRound: Seeed_GFX GC9A01 init complete",
                "DisplayRound: boot screen drawn",
                "DisplayRound: map frame route lines=3 elapsed_ms=12",
                "RoundUi: touch start x=120 y=90",
                "RoundUi: gesture=tap",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (root / "ios-ble-session.log").write_text(
        serial_log(
            diagnostic(
                1,
                1000,
                connect_count=1,
                auth_successes=1,
                auth=1,
                nav_packets=1,
                route_packets=1,
                gps_packets=1,
                settings_packets=1,
                route_stored_pts=2,
                route_total_m=10,
            )
        ),
        encoding="utf-8",
    )
    (root / "ios-ble-reconnect.log").write_text(
        serial_log(
            diagnostic(1, 1000, connect_count=1, auth_successes=1, auth=1),
            diagnostic(
                2,
                2000,
                connect_count=2,
                disconnect_count=1,
                auth_successes=2,
                auth=1,
                nav_packets=1,
                route_packets=1,
                gps_packets=1,
                settings_packets=1,
                session_nav_packets=1,
                session_route_packets=1,
                session_gps_packets=1,
                session_settings_packets=1,
                route_stored_pts=2,
                route_total_m=10,
            ),
        ),
        encoding="utf-8",
    )
    ride_snapshots = [
        diagnostic(
            index,
            index * 300000,
            connect_count=1,
            auth_successes=1,
            auth=1,
            nav_packets=1,
            route_packets=1,
            gps_packets=3600 if index == 12 else index * 300,
            gps_fresh=1,
            settings_packets=1,
            route_stored_pts=2,
            route_total_m=10,
            render_max_ms=90,
        )
        for index in range(1, 13)
    ]
    (root / "ios-ble-ride-60.log").write_text(
        serial_log(*ride_snapshots),
        encoding="utf-8",
    )
    (root / "serial-soak-60.log").write_text(
        serial_log(*ride_snapshots),
        encoding="utf-8",
    )
    (root / "route-duplicate.log").write_text(
        serial_log(
            diagnostic(
                1,
                1000,
                route_packets=1,
                route_duplicates=1,
                route_stored_pts=2,
                route_total_m=10,
            )
        ),
        encoding="utf-8",
    )
    (root / "power-rtc-calibration.log").write_text(
        serial_log(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 scale_permille=2000",
            diagnostic(
                1,
                1000,
                battery_mv=4100,
                battery_pct=82,
                battery_scale_permille=2000,
                rtc_present=1,
                rtc_valid=1,
                rtc_source="ble",
            ),
        ),
        encoding="utf-8",
    )
    (root / "power-runtime.log").write_text(
        serial_log(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 scale_permille=2000",
            diagnostic(
                1,
                1000,
                battery_mv=4100,
                battery_pct=82,
                battery_scale_permille=2000,
                brightness=80,
            ),
            diagnostic(
                2,
                2000,
                battery_mv=3500,
                battery_pct=35,
                battery_scale_permille=2000,
                brightness=80,
            ),
            "EVIDENCE runtime_minutes=95 thermal_max_c=42 "
            "start_battery_mv=4120 end_battery_mv=3480 brightness_pct=80",
        ),
        encoding="utf-8",
    )
    (root / "power-screen-off-recovery.log").write_text(
        serial_log(
            diagnostic(
                1,
                1000,
                screen_off=1,
                brightness=0,
                connect_count=1,
                disconnect_count=1,
                auth_successes=1,
                auth=0,
                idle_calls=1,
                idle_total_ms=250,
                idle_last_ms=250,
                idle_last_screen_off=1,
            ),
            "RoundUi: gesture=tap",
            diagnostic(
                2,
                2000,
                screen_off=0,
                brightness=60,
                connect_count=2,
                disconnect_count=1,
                auth_successes=2,
                auth=1,
                idle_calls=2,
                idle_total_ms=260,
                idle_last_ms=10,
                idle_last_screen_off=0,
            ),
        ),
        encoding="utf-8",
    )
    (root / "map-lite.log").write_text(
        map_lite_log
        or serial_log(
            diagnostic(
                1,
                1000,
                map_sd=1,
                map_enabled=1,
                map_has_probe=1,
                map_probes=1,
                map_from_gps=1,
                map_found=1,
                map_decision="candidate",
                map_renders=1,
                map_render_valid=1,
                map_open_ms=2,
                map_scan_ms=10,
                map_render_ms=10,
                map_render_segments=3,
                map_render_budget=0,
            )
        ),
        encoding="utf-8",
    )


class EvidenceBundleCheckTests(unittest.TestCase):
    def test_accepts_complete_candidate_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write_bundle(root)

            results = evidence_bundle_check.validate_bundle(root, require_map_lite=True)

        self.assertTrue(all(result.passed for result in results))

    def test_reports_missing_required_log(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write_bundle(root)
            (root / "route-duplicate.log").unlink()

            results = evidence_bundle_check.validate_bundle(root, require_map_lite=True)

        failed = {result.key: result.issues for result in results if not result.passed}
        self.assertIn("route-duplicate", failed)
        self.assertIn(
            "missing required log: route-duplicate.log",
            failed["route-duplicate"],
        )

    def test_rejects_route_duplicate_log_without_debounce_counter(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write_bundle(root)
            (root / "route-duplicate.log").write_text(
                serial_log(
                    diagnostic(
                        1,
                        1000,
                        route_packets=1,
                        route_duplicates=0,
                        route_stored_pts=2,
                        route_total_m=10,
                    )
                ),
                encoding="utf-8",
            )

            results = evidence_bundle_check.validate_bundle(root, require_map_lite=True)

        failed = {result.key: result.issues for result in results if not result.passed}
        self.assertIn("route-duplicate", failed)
        self.assertIn(
            "route_duplicates 0 below minimum 1",
            failed["route-duplicate"],
        )

    def test_accepts_measured_map_lite_no_go(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write_bundle(
                root,
                map_lite_log=serial_log(
                    diagnostic(
                        1,
                        1000,
                        map_sd=1,
                        map_enabled=1,
                        map_has_probe=1,
                        map_probes=1,
                        map_from_gps=1,
                        map_found=1,
                        map_decision="too-slow",
                        map_renders=0,
                        map_open_ms=2,
                        map_scan_ms=220,
                        map_render_ms=0,
                        map_render_budget=0,
                    )
                ),
            )

            results = evidence_bundle_check.validate_bundle(root, require_map_lite=True)

        self.assertTrue(all(result.passed for result in results))

    def test_rejects_map_lite_no_go_without_measured_timing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write_bundle(
                root,
                map_lite_log=serial_log(
                    diagnostic(
                        1,
                        1000,
                        map_sd=1,
                        map_enabled=1,
                        map_has_probe=1,
                        map_probes=1,
                        map_from_gps=1,
                        map_found=1,
                        map_decision="too-slow",
                        map_renders=0,
                        map_render_budget=0,
                    )
                ),
            )

            results = evidence_bundle_check.validate_bundle(root, require_map_lite=True)

        failed = {result.key: result.issues for result in results if not result.passed}
        self.assertIn("map-lite", failed)
        self.assertIn(
            "missing numeric diagnostic field: map_open_ms",
            failed["map-lite"],
        )
        self.assertIn(
            "missing numeric diagnostic field: map_scan_ms",
            failed["map-lite"],
        )

    def test_skip_map_lite_allows_missing_optional_log(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write_bundle(root)
            (root / "map-lite.log").unlink()

            results = evidence_bundle_check.validate_bundle(root, require_map_lite=False)

        self.assertTrue(all(result.passed for result in results))

    def test_main_returns_failure_for_incomplete_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                exit_code = evidence_bundle_check.main([temp_dir])

        self.assertEqual(1, exit_code)
        self.assertIn("FAIL hardware-bringup", output.getvalue())


if __name__ == "__main__":
    unittest.main()
