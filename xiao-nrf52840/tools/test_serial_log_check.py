#!/usr/bin/env python3
"""Regression tests for XIAO serial evidence validation profiles."""

from __future__ import annotations

import unittest

import serial_log_check


BOOT_LINES = [
    "Diagnostics: boot free_heap_approx=100000",
    "Diagnostics: reset_reason=0x0 reset_flags=none",
]


def issues_for(*snapshot_lines: str, args: list[str] | None = None) -> list[str]:
    parsed_args = serial_log_check.parse_args(["-", *(args or [])])
    parsed = serial_log_check.parse_log(
        [*BOOT_LINES, *snapshot_lines],
        allow_rejections=parsed_args.allow_rejections,
    )
    return serial_log_check.validate(parsed, parsed_args)


class PowerRtcCalibrationProfileTests(unittest.TestCase):
    def test_accepts_complete_power_rtc_snapshot(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2050 rtc_present=1 rtc_valid=1 "
            "rtc_source=ble",
            args=["--profile", "power-rtc-calibration"],
        )

        self.assertEqual([], issues)

    def test_rejects_power_rtc_snapshot_without_batcal_evidence(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2000 rtc_present=1 rtc_valid=1 "
            "rtc_source=ble",
            args=["--profile", "power-rtc-calibration"],
        )

        self.assertIn("missing battery calibration command evidence", issues)

    def test_rejects_low_battery_reading_even_with_valid_earlier_snapshot(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2050 rtc_present=1 rtc_valid=1 "
            "rtc_source=ble",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 battery_mv=2500 battery_pct=82 "
            "battery_scale_permille=2050 rtc_present=1 rtc_valid=1 "
            "rtc_source=ble",
            args=["--profile", "power-rtc-calibration"],
        )

        self.assertIn("battery_mv minimum 2500 below 3000", issues)

    def test_rejects_negative_battery_percentage(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=-1 "
            "battery_scale_permille=2050 rtc_present=1 rtc_valid=1 "
            "rtc_source=ble",
            args=["--profile", "power-rtc-calibration"],
        )

        self.assertIn("battery_pct minimum -1 below 0", issues)

    def test_rejects_power_and_rtc_evidence_split_across_snapshots(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2050 rtc_present=0 rtc_valid=0 "
            "rtc_source=unknown",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 battery_mv=2500 battery_pct=82 "
            "battery_scale_permille=2050 rtc_present=1 rtc_valid=1 "
            "rtc_source=ble",
            args=["--profile", "power-rtc-calibration"],
        )

        self.assertIn(
            "missing complete power/RTC calibration evidence snapshot after BATCAL",
            issues,
        )

    def test_rejects_power_rtc_snapshot_before_batcal_evidence(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2050 rtc_present=1 rtc_valid=1 "
            "rtc_source=ble",
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            args=["--profile", "power-rtc-calibration"],
        )

        self.assertIn(
            "missing complete power/RTC calibration evidence snapshot after BATCAL",
            issues,
        )

    def test_rejects_failed_batcal_before_successful_calibration(self) -> None:
        issues = issues_for(
            "Power: BATCAL failed, battery ADC is not valid yet",
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2050 rtc_present=1 rtc_valid=1 "
            "rtc_source=ble",
            args=["--profile", "power-rtc-calibration"],
        )

        self.assertTrue(
            any("Power: BATCAL failed" in issue for issue in issues)
        )


class PowerRuntimeProfileTests(unittest.TestCase):
    def test_accepts_complete_measured_power_runtime_evidence(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "EVIDENCE runtime_minutes=95 thermal_max_c=42 "
            "start_battery_mv=4120 end_battery_mv=3480 brightness_pct=80",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2000 brightness=80",
            "Diagnostics: runtime heartbeat=2 uptime_ms=5700000 "
            "free_heap_approx=98000 battery_mv=3480 battery_pct=18 "
            "battery_scale_permille=2000 brightness=80",
            args=["--profile", "power-runtime"],
        )

        self.assertEqual([], issues)

    def test_rejects_power_runtime_without_measured_runtime(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "EVIDENCE thermal_max_c=42 start_battery_mv=4120 "
            "end_battery_mv=3480 brightness_pct=80",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2000 brightness=80",
            "Diagnostics: runtime heartbeat=2 uptime_ms=5700000 "
            "free_heap_approx=98000 battery_mv=3480 battery_pct=18 "
            "battery_scale_permille=2000 brightness=80",
            args=["--profile", "power-runtime"],
        )

        self.assertIn("missing numeric evidence field: runtime_minutes", issues)
        self.assertIn("missing complete measured power runtime evidence", issues)

    def test_rejects_power_runtime_with_hot_thermal_reading(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "EVIDENCE runtime_minutes=95 thermal_max_c=51 "
            "start_battery_mv=4120 end_battery_mv=3480 brightness_pct=80",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2000 brightness=80",
            "Diagnostics: runtime heartbeat=2 uptime_ms=5700000 "
            "free_heap_approx=98000 battery_mv=3480 battery_pct=18 "
            "battery_scale_permille=2000 brightness=80",
            args=["--profile", "power-runtime"],
        )

        self.assertIn("thermal_max_c 51 exceeds 50", issues)
        self.assertIn("missing complete measured power runtime evidence", issues)

    def test_rejects_power_runtime_without_voltage_drop(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "EVIDENCE runtime_minutes=95 thermal_max_c=42 "
            "start_battery_mv=4120 end_battery_mv=4090 brightness_pct=80",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2000 brightness=80",
            "Diagnostics: runtime heartbeat=2 uptime_ms=5700000 "
            "free_heap_approx=98000 battery_mv=4090 battery_pct=81 "
            "battery_scale_permille=2000 brightness=80",
            args=["--profile", "power-runtime"],
        )

        self.assertIn("battery voltage drop 30 below minimum 50", issues)

    def test_rejects_power_runtime_with_implausible_measured_voltage(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "EVIDENCE runtime_minutes=95 thermal_max_c=42 "
            "start_battery_mv=9000 end_battery_mv=3480 brightness_pct=80",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2000 brightness=80",
            "Diagnostics: runtime heartbeat=2 uptime_ms=5700000 "
            "free_heap_approx=98000 battery_mv=3480 battery_pct=18 "
            "battery_scale_permille=2000 brightness=80",
            args=["--profile", "power-runtime"],
        )

        self.assertIn("start_battery_mv 9000 outside 3000..4300", issues)
        self.assertIn("missing complete measured power runtime evidence", issues)

    def test_rejects_power_runtime_when_start_voltage_does_not_match_diagnostics(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "EVIDENCE runtime_minutes=95 thermal_max_c=42 "
            "start_battery_mv=4120 end_battery_mv=3480 brightness_pct=80",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=3900 battery_pct=65 "
            "battery_scale_permille=2000 brightness=80",
            "Diagnostics: runtime heartbeat=2 uptime_ms=5700000 "
            "free_heap_approx=98000 battery_mv=3480 battery_pct=18 "
            "battery_scale_permille=2000 brightness=80",
            args=["--profile", "power-runtime"],
        )

        self.assertIn(
            "start_battery_mv 4120 differs from diagnostic maximum 3900 by more than 150",
            issues,
        )
        self.assertIn("missing complete measured power runtime evidence", issues)

    def test_rejects_power_runtime_when_end_voltage_does_not_match_diagnostics(self) -> None:
        issues = issues_for(
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "EVIDENCE runtime_minutes=95 thermal_max_c=42 "
            "start_battery_mv=4120 end_battery_mv=3480 brightness_pct=80",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2000 brightness=80",
            "Diagnostics: runtime heartbeat=2 uptime_ms=5700000 "
            "free_heap_approx=98000 battery_mv=3700 battery_pct=45 "
            "battery_scale_permille=2000 brightness=80",
            args=["--profile", "power-runtime"],
        )

        self.assertIn(
            "end_battery_mv 3480 differs from diagnostic minimum 3700 by more than 150",
            issues,
        )
        self.assertIn("missing complete measured power runtime evidence", issues)

    def test_rejects_power_runtime_without_calibrated_snapshot_after_batcal(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 battery_mv=4100 battery_pct=82 "
            "battery_scale_permille=2000 brightness=80",
            "Power: battery calibration measured_mv=4100 pin_mv=2050 "
            "scale_permille=2000",
            "EVIDENCE runtime_minutes=95 thermal_max_c=42 "
            "start_battery_mv=4120 end_battery_mv=3480 brightness_pct=80",
            args=["--profile", "power-runtime"],
        )

        self.assertIn(
            "missing complete calibrated battery evidence snapshot after BATCAL",
            issues,
        )


class MapLiteCandidateProfileTests(unittest.TestCase):
    def test_accepts_complete_candidate_render_snapshot(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=1 map_sd=1 map_found=1 map_from_gps=1 "
            "map_decision=candidate map_renders=1 map_render_valid=1 "
            "map_scan_ms=10 map_render_ms=10 map_render_segments=3 "
            "map_render_budget=0",
            args=["--profile", "map-lite-candidate"],
        )

        self.assertEqual([], issues)

    def test_rejects_candidate_without_valid_render(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=1 map_sd=1 map_found=1 map_from_gps=1 "
            "map_decision=candidate map_renders=1 map_render_valid=0 "
            "map_scan_ms=10 map_render_ms=10 map_render_segments=3 "
            "map_render_budget=0",
            args=["--profile", "map-lite-candidate"],
        )

        self.assertIn("missing valid map-lite render evidence", issues)
        self.assertIn("missing complete map-lite candidate evidence snapshot", issues)

    def test_rejects_candidate_and_render_evidence_split_across_snapshots(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=1 map_sd=1 map_found=1 map_from_gps=1 "
            "map_decision=candidate map_renders=1 map_render_valid=0 "
            "map_scan_ms=10 map_render_ms=10 map_render_segments=3 "
            "map_render_budget=0",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=1 map_sd=1 map_found=1 map_from_gps=1 "
            "map_decision=no-data map_renders=1 map_render_valid=1 "
            "map_scan_ms=10 map_render_ms=10 map_render_segments=3 "
            "map_render_budget=0",
            args=["--profile", "map-lite-candidate"],
        )

        self.assertIn("missing complete map-lite candidate evidence snapshot", issues)

    def test_rejects_candidate_without_sd_found_or_gps_probe(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=1 map_sd=0 map_found=0 map_from_gps=0 "
            "map_decision=candidate map_renders=1 map_render_valid=1 "
            "map_scan_ms=10 map_render_ms=10 map_render_segments=3 "
            "map_render_budget=0",
            args=["--profile", "map-lite-candidate"],
        )

        self.assertIn("missing map-lite SD-ready evidence", issues)
        self.assertIn("missing map-lite found-block evidence", issues)
        self.assertIn("missing GPS-driven map-lite probe evidence", issues)
        self.assertIn("missing complete map-lite candidate evidence snapshot", issues)

    def test_rejects_candidate_without_drawn_map_segments(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=1 map_sd=1 map_found=1 map_from_gps=1 "
            "map_decision=candidate map_renders=1 map_render_valid=1 "
            "map_scan_ms=10 map_render_ms=10 map_render_segments=0 "
            "map_render_budget=0",
            args=["--profile", "map-lite-candidate"],
        )

        self.assertIn("map_render_segments 0 below minimum 1", issues)
        self.assertIn("missing complete map-lite candidate evidence snapshot", issues)

    def test_rejects_candidate_without_scan_timing(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=1 map_sd=1 map_found=1 map_from_gps=1 "
            "map_decision=candidate map_renders=1 map_render_valid=1 "
            "map_render_ms=10 map_render_segments=3 map_render_budget=0",
            args=["--profile", "map-lite-candidate"],
        )

        self.assertIn("missing numeric diagnostic field: map_scan_ms", issues)
        self.assertIn("missing complete map-lite candidate evidence snapshot", issues)

    def test_rejects_candidate_without_render_timing(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=1 map_sd=1 map_found=1 map_from_gps=1 "
            "map_decision=candidate map_renders=1 map_render_valid=1 "
            "map_scan_ms=10 map_render_segments=3 map_render_budget=0",
            args=["--profile", "map-lite-candidate"],
        )

        self.assertIn("missing numeric diagnostic field: map_render_ms", issues)
        self.assertIn("missing complete map-lite candidate evidence snapshot", issues)

    def test_rejects_candidate_without_experiment_enabled(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_enabled=0 map_sd=1 map_found=1 map_from_gps=1 "
            "map_decision=candidate map_renders=1 map_render_valid=1 "
            "map_scan_ms=10 map_render_ms=10 map_render_segments=3 "
            "map_render_budget=0",
            args=["--profile", "map-lite-candidate"],
        )

        self.assertIn("missing map-lite experiment enable evidence", issues)
        self.assertIn("missing complete map-lite candidate evidence snapshot", issues)

    def test_explicit_no_go_check_does_not_require_candidate_render(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 map_probes=1 map_has_probe=1 "
            "map_decision=too-slow map_renders=0 map_scan_ms=220 "
            "map_render_ms=0 map_render_budget=0",
            args=[
                "--require-map-probe",
                "--require-map-decision",
                "too-slow",
                "--max-map-scan-ms",
                "250",
                "--fail-map-render-budget",
            ],
        )

        self.assertEqual([], issues)


class IosBleSessionProfileTests(unittest.TestCase):
    def test_accepts_real_authenticated_ios_session_snapshot(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 auth_successes=1 auth=1 "
            "nav_packets=1 route_packets=1 gps_packets=1 settings_packets=1 "
            "route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-session"],
        )

        self.assertEqual([], issues)

    def test_rejects_unauthenticated_ios_session_snapshot(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 auth_successes=1 auth=0 "
            "nav_packets=1 route_packets=1 gps_packets=1 settings_packets=1 "
            "route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-session"],
        )

        self.assertIn("missing authenticated BLE session evidence", issues)
        self.assertIn("missing complete authenticated iOS BLE evidence snapshot", issues)

    def test_rejects_ios_session_without_route_distance(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 auth_successes=1 auth=1 "
            "nav_packets=1 route_packets=1 gps_packets=1 settings_packets=1 "
            "route_stored_pts=2 route_total_m=0",
            args=["--profile", "ios-ble-session"],
        )

        self.assertIn("route_total_m 0 below minimum 1", issues)

    def test_rejects_simulation_evidence(self) -> None:
        issues = issues_for(
            "SerialSim: serial simulation session enabled",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 auth_successes=1 auth=1 "
            "nav_packets=1 route_packets=1 gps_packets=1 settings_packets=1 "
            "route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-session"],
        )

        self.assertTrue(
            any(
                issue.startswith("simulation session evidence present")
                for issue in issues
            )
        )

    def test_rejects_ios_session_evidence_split_across_snapshots(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 auth_successes=1 auth=1 "
            "nav_packets=0 route_packets=0 gps_packets=0 settings_packets=0 "
            "route_stored_pts=0 route_total_m=0",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 connect_count=1 auth_successes=1 auth=0 "
            "nav_packets=1 route_packets=1 gps_packets=1 settings_packets=1 "
            "route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-session"],
        )

        self.assertIn("missing complete authenticated iOS BLE evidence snapshot", issues)


class IosBleReconnectProfileTests(unittest.TestCase):
    def test_accepts_post_reconnect_ios_session_snapshot(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 disconnect_count=0 "
            "auth_successes=1 auth=1 nav_packets=1 route_packets=1 "
            "gps_packets=1 settings_packets=1 session_nav_packets=1 "
            "session_route_packets=1 session_route_duplicates=0 "
            "session_gps_packets=1 "
            "session_settings_packets=1 route_stored_pts=2 route_total_m=10",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 connect_count=2 disconnect_count=1 "
            "auth_successes=2 auth=1 nav_packets=2 route_packets=2 "
            "gps_packets=2 settings_packets=2 session_nav_packets=1 "
            "session_route_packets=1 session_route_duplicates=0 "
            "session_gps_packets=1 "
            "session_settings_packets=1 route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-reconnect"],
        )

        self.assertEqual([], issues)

    def test_accepts_post_reconnect_duplicate_route_resend(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 disconnect_count=0 "
            "auth_successes=1 auth=1 nav_packets=1 route_packets=1 "
            "route_duplicates=0 gps_packets=1 settings_packets=1 "
            "session_nav_packets=1 session_route_packets=1 "
            "session_route_duplicates=0 session_gps_packets=1 "
            "session_settings_packets=1 route_stored_pts=2 route_total_m=10",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 connect_count=2 disconnect_count=1 "
            "auth_successes=2 auth=1 nav_packets=2 route_packets=1 "
            "route_duplicates=1 gps_packets=2 settings_packets=2 "
            "session_nav_packets=1 session_route_packets=0 "
            "session_route_duplicates=1 session_gps_packets=1 "
            "session_settings_packets=1 route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-reconnect"],
        )

        self.assertEqual([], issues)

    def test_rejects_reconnect_without_post_reconnect_writes(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 disconnect_count=0 "
            "auth_successes=1 auth=1 nav_packets=1 route_packets=1 "
            "gps_packets=1 settings_packets=1 session_nav_packets=1 "
            "session_route_packets=1 session_route_duplicates=0 "
            "session_gps_packets=1 "
            "session_settings_packets=1 route_stored_pts=2 route_total_m=10",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 connect_count=2 disconnect_count=1 "
            "auth_successes=2 auth=1 nav_packets=1 route_packets=1 "
            "gps_packets=1 settings_packets=1 session_nav_packets=0 "
            "session_route_packets=0 session_route_duplicates=0 "
            "session_gps_packets=0 "
            "session_settings_packets=0 route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-reconnect"],
        )

        self.assertIn("missing complete post-reconnect iOS BLE evidence snapshot", issues)

    def test_rejects_reconnect_profile_without_ordered_counter_increase(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=2 disconnect_count=1 "
            "auth_successes=2 auth=1 nav_packets=2 route_packets=2 "
            "gps_packets=2 settings_packets=2 session_nav_packets=1 "
            "session_route_packets=1 session_route_duplicates=0 "
            "session_gps_packets=1 "
            "session_settings_packets=1 route_stored_pts=2 route_total_m=10",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 connect_count=2 disconnect_count=1 "
            "auth_successes=2 auth=1 nav_packets=2 route_packets=2 "
            "gps_packets=2 settings_packets=2 session_nav_packets=1 "
            "session_route_packets=1 session_route_duplicates=0 "
            "session_gps_packets=1 "
            "session_settings_packets=1 route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-reconnect"],
        )

        self.assertIn("missing complete post-reconnect iOS BLE evidence snapshot", issues)

    def test_rejects_reconnect_profile_with_serial_simulation_evidence(self) -> None:
        issues = issues_for(
            "SerialSim: serial simulation session enabled",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=2 disconnect_count=1 "
            "auth_successes=2 auth=1 nav_packets=2 route_packets=2 "
            "gps_packets=2 settings_packets=2 session_nav_packets=1 "
            "session_route_packets=1 session_route_duplicates=0 "
            "session_gps_packets=1 "
            "session_settings_packets=1 route_stored_pts=2 route_total_m=10",
            args=["--profile", "ios-ble-reconnect"],
        )

        self.assertTrue(
            any(
                issue.startswith("simulation session evidence present")
                for issue in issues
            )
        )


class IosBleRide60ProfileTests(unittest.TestCase):
    def ride_snapshots(
        self,
        *,
        final_uptime_ms: int = 3_600_000,
        include_render: bool = True,
        render_max_ms: int = 80,
        final_auth: int = 1,
        final_gps_fresh: int = 1,
    ) -> list[str]:
        snapshots: list[str] = []
        for index in range(1, 13):
            uptime_ms = final_uptime_ms if index == 12 else index * 300_000
            gps_packets = 3_600 if index == 12 else index * 300
            auth = final_auth if index == 12 else 1
            gps_fresh = final_gps_fresh if index == 12 else 1
            render = f" render_max_ms={render_max_ms}" if include_render else ""
            snapshots.append(
                "Diagnostics: runtime "
                f"heartbeat={index} uptime_ms={uptime_ms} "
                "free_heap_approx=99000 connect_count=1 auth_successes=1 "
                f"auth={auth} nav_packets=1 route_packets=1 "
                f"gps_packets={gps_packets} gps_fresh={gps_fresh} settings_packets=1 "
                f"route_stored_pts=2 route_total_m=10{render}"
            )
        return snapshots

    def test_accepts_complete_real_ios_ride_60_snapshot(self) -> None:
        issues = issues_for(
            *self.ride_snapshots(),
            args=["--profile", "ios-ble-ride-60"],
        )

        self.assertEqual([], issues)

    def test_rejects_serial_simulation_for_ios_ride_60(self) -> None:
        issues = issues_for(
            "SerialSim: serial simulation session enabled",
            *self.ride_snapshots(),
            args=["--profile", "ios-ble-ride-60"],
        )

        self.assertTrue(
            any(
                issue.startswith("simulation session evidence present")
                for issue in issues
            )
        )

    def test_rejects_short_ios_ride_duration(self) -> None:
        issues = issues_for(
            *self.ride_snapshots(final_uptime_ms=3_599_999),
            args=["--profile", "ios-ble-ride-60"],
        )

        self.assertIn("max uptime 3599999 ms below minimum 3600000 ms", issues)

    def test_rejects_ios_ride_when_duration_is_not_in_complete_snapshot(self) -> None:
        issues = issues_for(
            *self.ride_snapshots(final_uptime_ms=3_300_000),
            "heartbeat=999 uptime_ms=3600000",
            args=["--profile", "ios-ble-ride-60"],
        )

        self.assertIn("missing complete 60-minute iOS BLE ride evidence snapshot", issues)

    def test_rejects_ios_ride_without_render_timing(self) -> None:
        issues = issues_for(
            *self.ride_snapshots(include_render=False),
            args=["--profile", "ios-ble-ride-60"],
        )

        self.assertIn("missing diagnostic field: render_max_ms", issues)
        self.assertIn("missing complete 60-minute iOS BLE ride evidence snapshot", issues)

    def test_rejects_ios_ride_over_render_budget(self) -> None:
        issues = issues_for(
            *self.ride_snapshots(render_max_ms=151),
            args=["--profile", "ios-ble-ride-60"],
        )

        self.assertIn("render_max_ms 151 exceeds 150", issues)
        self.assertIn("missing complete 60-minute iOS BLE ride evidence snapshot", issues)

    def test_rejects_ios_ride_when_final_gps_is_stale(self) -> None:
        issues = issues_for(
            *self.ride_snapshots(final_gps_fresh=0),
            args=["--profile", "ios-ble-ride-60"],
        )

        self.assertIn("missing complete 60-minute iOS BLE ride evidence snapshot", issues)

    def test_rejects_ios_ride_evidence_split_across_snapshots(self) -> None:
        issues = issues_for(
            *self.ride_snapshots(final_auth=0),
            args=["--profile", "ios-ble-ride-60"],
        )

        self.assertIn("missing complete 60-minute iOS BLE ride evidence snapshot", issues)


class RideRobustnessEvidenceGateTests(unittest.TestCase):
    def test_accepts_duplicate_route_debounce_evidence(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 route_packets=1 route_duplicates=1",
            args=["--min-route-packets", "1", "--min-route-duplicates", "1"],
        )

        self.assertEqual([], issues)

    def test_rejects_serial_simulator_parse_errors_even_with_valid_snapshot(self) -> None:
        issues = issues_for(
            "SerialSim: GPS expects lat lon [heading unix speed alt distance elapsed remaining]",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 route_packets=1 route_duplicates=1",
            args=["--min-route-packets", "1", "--min-route-duplicates", "1"],
        )

        self.assertTrue(
            any(
                "SerialSim: GPS expects" in issue
                for issue in issues
            )
        )

    def test_rejects_invalid_serial_hex_payloads(self) -> None:
        issues = issues_for(
            "SerialSim: invalid GPSHEX payload",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 gps_packets=1",
            args=["--min-gps-packets", "1"],
        )

        self.assertTrue(
            any("SerialSim: invalid GPSHEX payload" in issue for issue in issues)
        )

    def test_rejects_missing_duplicate_route_debounce_evidence(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 route_packets=1 route_duplicates=0",
            args=["--min-route-packets", "1", "--min-route-duplicates", "1"],
        )

        self.assertIn("route_duplicates 0 below minimum 1", issues)

    def test_accepts_reconnect_reset_evidence(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=1 disconnect_count=0 "
            "ble_resets=0",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 connect_count=2 disconnect_count=1 "
            "ble_resets=1",
            args=["--min-connects", "2", "--min-disconnects", "1", "--min-ble-resets", "1"],
        )

        self.assertEqual([], issues)

    def test_rejects_reconnect_log_without_disconnect_evidence(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 connect_count=2 disconnect_count=0 "
            "ble_resets=1",
            args=["--min-connects", "2", "--min-disconnects", "1", "--min-ble-resets", "1"],
        )

        self.assertIn("disconnect_count 0 below minimum 1", issues)

    def test_accepts_screen_off_idle_and_recovery_evidence(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "idle_calls=2 idle_total_ms=260 idle_last_ms=10 "
            "idle_last_screen_off=0",
            args=[
                "--require-screen-off",
                "--require-screen-off-idle",
                "--require-screen-on-after-off",
                "--min-idle-calls",
                "1",
                "--min-idle-total-ms",
                "1",
            ],
        )

        self.assertEqual([], issues)

    def test_accepts_power_screen_off_recovery_profile(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "connect_count=1 disconnect_count=1 auth_successes=1 auth=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            "RoundUi: gesture=tap",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "connect_count=2 disconnect_count=1 auth_successes=2 auth=1 "
            "idle_calls=2 idle_total_ms=260 idle_last_ms=10 "
            "idle_last_screen_off=0",
            args=["--profile", "power-screen-off-recovery"],
        )

        self.assertEqual([], issues)

    def test_rejects_power_screen_off_recovery_without_touch_wake(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "connect_count=1 disconnect_count=1 auth_successes=1 auth=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "connect_count=2 disconnect_count=1 auth_successes=2 auth=1 "
            "idle_calls=2 idle_total_ms=260 idle_last_ms=10 "
            "idle_last_screen_off=0",
            args=["--profile", "power-screen-off-recovery"],
        )

        self.assertIn("missing touch wake gesture evidence", issues)
        self.assertIn(
            "missing complete screen-off touch and BLE recovery sequence",
            issues,
        )

    def test_rejects_touch_before_screen_off_recovery_sequence(self) -> None:
        issues = issues_for(
            "RoundUi: gesture=tap",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "connect_count=1 disconnect_count=1 auth_successes=1 auth=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "connect_count=2 disconnect_count=1 auth_successes=2 auth=1 "
            "idle_calls=2 idle_total_ms=260 idle_last_ms=10 "
            "idle_last_screen_off=0",
            args=["--profile", "power-screen-off-recovery"],
        )

        self.assertIn(
            "missing complete screen-off touch and BLE recovery sequence",
            issues,
        )

    def test_rejects_recovery_snapshot_before_touch_wake(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "connect_count=1 disconnect_count=1 auth_successes=1 auth=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "connect_count=2 disconnect_count=1 auth_successes=2 auth=1 "
            "idle_calls=2 idle_total_ms=260 idle_last_ms=10 "
            "idle_last_screen_off=0",
            "RoundUi: gesture=tap",
            args=["--profile", "power-screen-off-recovery"],
        )

        self.assertIn(
            "missing complete screen-off touch and BLE recovery sequence",
            issues,
        )

    def test_rejects_screen_off_recovery_without_authenticated_reconnect(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "connect_count=1 disconnect_count=1 auth_successes=1 auth=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            "RoundUi: gesture=tap",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "connect_count=2 disconnect_count=1 auth_successes=1 auth=0 "
            "idle_calls=2 idle_total_ms=260 idle_last_ms=10 "
            "idle_last_screen_off=0",
            args=["--profile", "power-screen-off-recovery"],
        )

        self.assertIn("auth_successes 1 below minimum 2", issues)
        self.assertIn("missing authenticated BLE session evidence", issues)
        self.assertIn(
            "missing complete screen-off touch and BLE recovery sequence",
            issues,
        )

    def test_rejects_screen_off_recovery_with_stale_reconnect_counters(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "connect_count=2 disconnect_count=1 auth_successes=2 auth=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            "RoundUi: gesture=tap",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "connect_count=2 disconnect_count=1 auth_successes=2 auth=1 "
            "idle_calls=2 idle_total_ms=260 idle_last_ms=10 "
            "idle_last_screen_off=0",
            args=["--profile", "power-screen-off-recovery"],
        )

        self.assertIn(
            "missing complete screen-off touch and BLE recovery sequence",
            issues,
        )

    def test_rejects_screen_off_recovery_with_serial_simulation(self) -> None:
        issues = issues_for(
            "SerialSim: serial simulation session enabled",
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "connect_count=1 disconnect_count=1 auth_successes=1 auth=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            "RoundUi: gesture=tap",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "connect_count=2 disconnect_count=1 auth_successes=2 auth=1 "
            "idle_calls=2 idle_total_ms=260 idle_last_ms=10 "
            "idle_last_screen_off=0",
            args=["--profile", "power-screen-off-recovery"],
        )

        self.assertTrue(
            any(
                issue.startswith("simulation session evidence present")
                for issue in issues
            )
        )

    def test_rejects_screen_off_idle_evidence_split_across_snapshots(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "idle_calls=0 idle_total_ms=0 idle_last_ms=0 "
            "idle_last_screen_off=0",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            args=["--require-screen-off", "--require-screen-off-idle"],
        )

        self.assertIn("missing screen-off idle delay evidence", issues)

    def test_rejects_missing_screen_on_recovery_after_screen_off(self) -> None:
        issues = issues_for(
            "Diagnostics: runtime heartbeat=1 uptime_ms=1000 "
            "free_heap_approx=99000 screen_off=0 brightness=60 "
            "idle_calls=0 idle_total_ms=0 idle_last_ms=0 "
            "idle_last_screen_off=0",
            "Diagnostics: runtime heartbeat=2 uptime_ms=2000 "
            "free_heap_approx=99000 screen_off=1 brightness=0 "
            "idle_calls=1 idle_total_ms=250 idle_last_ms=250 "
            "idle_last_screen_off=1",
            args=[
                "--require-screen-off",
                "--require-screen-off-idle",
                "--require-screen-on-after-off",
            ],
        )

        self.assertIn("missing screen-on recovery after screen_off", issues)


if __name__ == "__main__":
    unittest.main()
