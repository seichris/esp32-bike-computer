#!/usr/bin/env python3
"""Validate XIAO firmware serial logs for bring-up and soak evidence."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, TextIO


DIAGNOSTIC_PREFIX = "Diagnostics: "
BOOT_HEAP_RE = re.compile(r"Diagnostics: boot free_heap_approx=(\d+)")
RESET_RE = re.compile(r"Diagnostics: reset_reason=(0x[0-9A-Fa-f]+)")
HEARTBEAT_RE = re.compile(r"heartbeat=\d+ uptime_ms=(\d+)")
KEY_VALUE_RE = re.compile(r"([A-Za-z0-9_]+)=([^ ]+)")
SIMULATION_RE = re.compile(
    r"\bserial simulation session (enabled|reset)\b|^SIM ON\b",
    re.IGNORECASE,
)
BATTERY_CALIBRATION_RE = re.compile(
    r"\bPower:\s+battery calibration measured_mv=\d+ .*scale_permille=\d+\b"
)
EVIDENCE_PREFIX = "EVIDENCE "
TOUCH_GESTURE_RE = re.compile(
    r"\bRoundUi:\s+gesture=(tap|long|left|right|up|down)\b"
)
DEFAULT_FORBIDDEN_PATTERNS = [
    ("init-failed", re.compile(r"\binit failed\b", re.IGNORECASE)),
    ("rejection", re.compile(r"\bBLE: rejected\b", re.IGNORECASE)),
    ("line-too-long", re.compile(r"\bline too long\b", re.IGNORECASE)),
    (
        "serial-sim-command-error",
        re.compile(
            r"\bSerialSim:\s+(?:.*\bexpects\b|invalid\b.*\bpayload\b|unknown command\b)",
            re.IGNORECASE,
        ),
    ),
    (
        "battery-calibration-error",
        re.compile(r"\bPower:\s+BATCAL\s+(?:expects|failed)\b", re.IGNORECASE),
    ),
    ("reboot", re.compile(r"\brebooting now\b", re.IGNORECASE)),
]
BAD_RESET_FLAGS = {"watchdog", "lockup"}


@dataclass
class DiagnosticSnapshot:
    label: str
    fields: dict[str, str]
    line_number: int

    def int_field(self, name: str, default: int = 0) -> int:
        value = self.fields.get(name)
        if value is None:
            return default
        try:
            return int(value, 0)
        except ValueError:
            return default


@dataclass
class ParsedLog:
    boot_heap: int | None = None
    reset_reason: str | None = None
    reset_flags: str | None = None
    max_uptime_ms: int = 0
    snapshots: list[DiagnosticSnapshot] = field(default_factory=list)
    forbidden_lines: list[tuple[int, str]] = field(default_factory=list)
    simulation_lines: list[tuple[int, str]] = field(default_factory=list)
    battery_calibration_lines: list[tuple[int, str]] = field(default_factory=list)
    evidence: dict[str, str] = field(default_factory=dict)
    evidence_lines: list[tuple[int, str]] = field(default_factory=list)
    touch_gesture_lines: list[tuple[int, str]] = field(default_factory=list)


def read_lines(path: str) -> list[str]:
    if path == "-":
        return [line.rstrip("\n") for line in sys.stdin]
    return Path(path).read_text(encoding="utf-8").splitlines()


def parse_snapshot(line: str, line_number: int) -> DiagnosticSnapshot | None:
    if not line.startswith(DIAGNOSTIC_PREFIX):
        return None
    if line.startswith("Diagnostics: reset_reason=") or line.startswith(
        "Diagnostics: boot "
    ):
        return None

    body = line[len(DIAGNOSTIC_PREFIX) :]
    first_space = body.find(" ")
    if first_space < 0:
        return None
    label = body[:first_space]
    fields = {match.group(1): match.group(2) for match in KEY_VALUE_RE.finditer(body)}
    if "free_heap_approx" not in fields:
        return None
    return DiagnosticSnapshot(label=label, fields=fields, line_number=line_number)


def parse_log(lines: Iterable[str], allow_rejections: bool) -> ParsedLog:
    parsed = ParsedLog()
    for index, line in enumerate(lines, start=1):
        boot_match = BOOT_HEAP_RE.search(line)
        if boot_match:
            parsed.boot_heap = int(boot_match.group(1))

        reset_match = RESET_RE.search(line)
        if reset_match and " reset_flags=" in line:
            parsed.reset_reason = reset_match.group(1)
            parsed.reset_flags = line.split(" reset_flags=", 1)[1].split(" ", 1)[0]

        heartbeat_match = HEARTBEAT_RE.search(line)
        if heartbeat_match:
            parsed.max_uptime_ms = max(parsed.max_uptime_ms, int(heartbeat_match.group(1)))

        snapshot = parse_snapshot(line, index)
        if snapshot is not None:
            parsed.snapshots.append(snapshot)

        if SIMULATION_RE.search(line):
            parsed.simulation_lines.append((index, line))

        if BATTERY_CALIBRATION_RE.search(line):
            parsed.battery_calibration_lines.append((index, line))

        if line.startswith(EVIDENCE_PREFIX):
            parsed.evidence_lines.append((index, line))
            parsed.evidence.update(
                {
                    match.group(1): match.group(2)
                    for match in KEY_VALUE_RE.finditer(
                        line[len(EVIDENCE_PREFIX) :]
                    )
                }
            )

        if TOUCH_GESTURE_RE.search(line):
            parsed.touch_gesture_lines.append((index, line))

        for name, pattern in DEFAULT_FORBIDDEN_PATTERNS:
            if allow_rejections and name == "rejection":
                continue
            if pattern.search(line):
                parsed.forbidden_lines.append((index, line))
                break
    return parsed


def int_arg(value: str) -> int:
    parsed = int(value, 0)
    if parsed < 0:
        raise argparse.ArgumentTypeError("value must be non-negative")
    return parsed


def apply_profile(args: argparse.Namespace) -> None:
    if args.profile == "generic":
        return
    if args.profile == "map-lite-candidate":
        args.min_snapshots = max(args.min_snapshots, 1)
        args.min_free_heap = max(args.min_free_heap, 1)
        args.min_map_probes = max(args.min_map_probes, 1)
        args.require_map_probe = True
        if args.require_map_decision is None:
            args.require_map_decision = []
        if "candidate" not in args.require_map_decision:
            args.require_map_decision.append("candidate")
        args.min_map_renders = max(args.min_map_renders, 1)
        args.min_map_render_segments = max(args.min_map_render_segments, 1)
        if args.max_map_scan_ms is None:
            args.max_map_scan_ms = 150
        if args.max_map_render_ms is None:
            args.max_map_render_ms = 150
        args.require_map_sd = True
        args.require_map_found = True
        args.require_map_from_gps = True
        args.require_map_enabled = True
        args.require_map_render_valid = True
        args.fail_map_render_budget = True
        return
    if args.profile == "ios-ble-session":
        args.min_snapshots = max(args.min_snapshots, 1)
        args.min_free_heap = max(args.min_free_heap, 1)
        args.min_connects = max(args.min_connects, 1)
        args.min_auth_successes = max(args.min_auth_successes, 1)
        args.min_nav_packets = max(args.min_nav_packets, 1)
        args.min_route_packets = max(args.min_route_packets, 1)
        args.min_gps_packets = max(args.min_gps_packets, 1)
        args.min_settings_packets = max(args.min_settings_packets, 1)
        args.min_route_stored_points = max(args.min_route_stored_points, 2)
        args.min_route_total_meters = max(args.min_route_total_meters, 1)
        args.require_authenticated = True
        args.forbid_simulation = True
        return
    if args.profile == "ios-ble-reconnect":
        args.min_snapshots = max(args.min_snapshots, 2)
        args.min_free_heap = max(args.min_free_heap, 1)
        args.min_connects = max(args.min_connects, 2)
        args.min_disconnects = max(args.min_disconnects, 1)
        args.min_auth_successes = max(args.min_auth_successes, 2)
        args.min_nav_packets = max(args.min_nav_packets, 1)
        args.min_route_packets = max(args.min_route_packets, 1)
        args.min_gps_packets = max(args.min_gps_packets, 1)
        args.min_settings_packets = max(args.min_settings_packets, 1)
        args.min_route_stored_points = max(args.min_route_stored_points, 2)
        args.min_route_total_meters = max(args.min_route_total_meters, 1)
        args.require_authenticated = True
        args.forbid_simulation = True
        return
    if args.profile == "ios-ble-ride-60":
        args.min_snapshots = max(args.min_snapshots, 12)
        args.min_uptime_ms = max(args.min_uptime_ms, 3_600_000)
        args.min_free_heap = max(args.min_free_heap, 1)
        args.min_connects = max(args.min_connects, 1)
        args.min_auth_successes = max(args.min_auth_successes, 1)
        args.min_nav_packets = max(args.min_nav_packets, 1)
        args.min_route_packets = max(args.min_route_packets, 1)
        args.min_gps_packets = max(args.min_gps_packets, 3_600)
        args.min_settings_packets = max(args.min_settings_packets, 1)
        args.min_route_stored_points = max(args.min_route_stored_points, 2)
        args.min_route_total_meters = max(args.min_route_total_meters, 1)
        if args.max_render_ms is None:
            args.max_render_ms = 150
        if args.require_diagnostic_field is None:
            args.require_diagnostic_field = []
        for field in ("gps_fresh",):
            if field not in args.require_diagnostic_field:
                args.require_diagnostic_field.append(field)
        args.require_authenticated = True
        args.forbid_simulation = True
        return
    if args.profile == "power-rtc-calibration":
        args.min_snapshots = max(args.min_snapshots, 1)
        args.min_free_heap = max(args.min_free_heap, 1)
        if args.require_diagnostic_field is None:
            args.require_diagnostic_field = []
        for field in (
            "battery_mv",
            "battery_pct",
            "battery_scale_permille",
            "rtc_present",
            "rtc_valid",
            "rtc_source",
        ):
            if field not in args.require_diagnostic_field:
                args.require_diagnostic_field.append(field)
        if args.min_battery_mv is None:
            args.min_battery_mv = 3000
        if args.max_battery_mv is None:
            args.max_battery_mv = 4300
        if args.min_battery_pct is None:
            args.min_battery_pct = 0
        if args.max_battery_pct is None:
            args.max_battery_pct = 100
        if args.min_battery_scale is None:
            args.min_battery_scale = 1000
        if args.max_battery_scale is None:
            args.max_battery_scale = 4000
        args.require_rtc_present = True
        args.require_rtc_valid = True
        if args.require_rtc_source is None:
            args.require_rtc_source = []
        for source in ("rtc", "ble"):
            if source not in args.require_rtc_source:
                args.require_rtc_source.append(source)
        args.require_battery_calibration = True
        return
    if args.profile == "power-runtime":
        args.min_snapshots = max(args.min_snapshots, 2)
        args.min_free_heap = max(args.min_free_heap, 1)
        if args.require_diagnostic_field is None:
            args.require_diagnostic_field = []
        for field in (
            "battery_mv",
            "battery_pct",
            "battery_scale_permille",
            "brightness",
        ):
            if field not in args.require_diagnostic_field:
                args.require_diagnostic_field.append(field)
        if args.min_battery_mv is None:
            args.min_battery_mv = 3000
        if args.max_battery_mv is None:
            args.max_battery_mv = 4300
        if args.min_battery_scale is None:
            args.min_battery_scale = 1000
        if args.max_battery_scale is None:
            args.max_battery_scale = 4000
        if args.min_runtime_minutes is None:
            args.min_runtime_minutes = 30
        if args.max_thermal_c is None:
            args.max_thermal_c = 50
        if args.min_voltage_drop_mv is None:
            args.min_voltage_drop_mv = 50
        if args.max_runtime_voltage_delta_mv is None:
            args.max_runtime_voltage_delta_mv = 150
        args.require_battery_calibration = True
        return
    if args.profile == "power-screen-off-recovery":
        args.min_snapshots = max(args.min_snapshots, 2)
        args.min_free_heap = max(args.min_free_heap, 1)
        args.min_connects = max(args.min_connects, 2)
        args.min_disconnects = max(args.min_disconnects, 1)
        args.min_auth_successes = max(args.min_auth_successes, 2)
        args.min_idle_calls = max(args.min_idle_calls, 1)
        args.min_idle_total_ms = max(args.min_idle_total_ms, 1)
        args.require_screen_off = True
        args.require_screen_off_idle = True
        args.require_screen_on_after_off = True
        args.require_touch_wake = True
        args.require_authenticated = True
        args.forbid_simulation = True
        return
    if args.profile != "serial-soak-60":
        return
    args.min_snapshots = max(args.min_snapshots, 12)
    args.min_uptime_ms = max(args.min_uptime_ms, 3_600_000)
    args.min_gps_packets = max(args.min_gps_packets, 3_600)
    args.min_nav_packets = max(args.min_nav_packets, 1)
    args.min_route_packets = max(args.min_route_packets, 1)
    args.min_settings_packets = max(args.min_settings_packets, 1)
    args.min_route_stored_points = max(args.min_route_stored_points, 2)
    args.min_route_total_meters = max(args.min_route_total_meters, 1)
    args.min_free_heap = max(args.min_free_heap, 1)


def latest_counter(parsed: ParsedLog, field: str) -> int:
    if not parsed.snapshots:
        return 0
    return max(snapshot.int_field(field) for snapshot in parsed.snapshots)


def numeric_values(parsed: ParsedLog, field: str) -> list[int]:
    values: list[int] = []
    for snapshot in parsed.snapshots:
        if field not in snapshot.fields:
            continue
        try:
            values.append(int(snapshot.fields[field], 0))
        except ValueError:
            continue
    return values


def check_numeric_range(
    issues: list[str],
    parsed: ParsedLog,
    field: str,
    minimum: int | None,
    maximum: int | None,
) -> None:
    if minimum is None and maximum is None:
        return
    values = numeric_values(parsed, field)
    if not values:
        issues.append(f"missing numeric diagnostic field: {field}")
        return
    observed_min = min(values)
    observed_max = max(values)
    if minimum is not None and observed_min < minimum:
        issues.append(f"{field} minimum {observed_min} below {minimum}")
    if maximum is not None and observed_max > maximum:
        issues.append(f"{field} maximum {observed_max} exceeds {maximum}")


def snapshot_int(snapshot: DiagnosticSnapshot, field: str) -> int | None:
    value = snapshot.fields.get(field)
    if value is None:
        return None
    try:
        return int(value, 0)
    except ValueError:
        return None


def int_in_range(
    value: int | None, minimum: int | None, maximum: int | None
) -> bool:
    if value is None:
        return False
    if minimum is not None and value < minimum:
        return False
    if maximum is not None and value > maximum:
        return False
    return True


def evidence_int(parsed: ParsedLog, field: str) -> int | None:
    value = parsed.evidence.get(field)
    if value is None:
        return None
    try:
        return int(value, 0)
    except ValueError:
        return None


def has_complete_power_rtc_snapshot(
    parsed: ParsedLog, args: argparse.Namespace
) -> bool:
    allowed_sources = set(args.require_rtc_source or [])
    for snapshot in parsed.snapshots:
        if args.require_battery_calibration and not any(
            line_number < snapshot.line_number
            for line_number, _ in parsed.battery_calibration_lines
        ):
            continue
        if not int_in_range(
            snapshot_int(snapshot, "battery_mv"),
            args.min_battery_mv,
            args.max_battery_mv,
        ):
            continue
        if not int_in_range(
            snapshot_int(snapshot, "battery_pct"),
            args.min_battery_pct,
            args.max_battery_pct,
        ):
            continue
        if not int_in_range(
            snapshot_int(snapshot, "battery_scale_permille"),
            args.min_battery_scale,
            args.max_battery_scale,
        ):
            continue
        if args.require_rtc_present and snapshot.int_field("rtc_present") == 0:
            continue
        if args.require_rtc_valid and snapshot.int_field("rtc_valid") == 0:
            continue
        if (
            allowed_sources
            and snapshot.fields.get("rtc_source") not in allowed_sources
        ):
            continue
        return True
    return False


def has_power_runtime_evidence(parsed: ParsedLog, args: argparse.Namespace) -> bool:
    runtime_minutes = evidence_int(parsed, "runtime_minutes")
    thermal_max_c = evidence_int(parsed, "thermal_max_c")
    start_battery_mv = evidence_int(parsed, "start_battery_mv")
    end_battery_mv = evidence_int(parsed, "end_battery_mv")
    brightness_pct = evidence_int(parsed, "brightness_pct")

    if runtime_minutes is None or runtime_minutes < args.min_runtime_minutes:
        return False
    if thermal_max_c is None or thermal_max_c > args.max_thermal_c:
        return False
    if thermal_max_c < 0:
        return False
    if start_battery_mv is None or end_battery_mv is None:
        return False
    if start_battery_mv < args.min_battery_mv or start_battery_mv > args.max_battery_mv:
        return False
    if end_battery_mv < args.min_battery_mv or end_battery_mv > args.max_battery_mv:
        return False
    if start_battery_mv - end_battery_mv < args.min_voltage_drop_mv:
        return False
    battery_values = numeric_values(parsed, "battery_mv")
    if args.max_runtime_voltage_delta_mv is not None:
        if not battery_values:
            return False
        observed_start_mv = max(battery_values)
        observed_end_mv = min(battery_values)
        if abs(observed_start_mv - start_battery_mv) > args.max_runtime_voltage_delta_mv:
            return False
        if abs(observed_end_mv - end_battery_mv) > args.max_runtime_voltage_delta_mv:
            return False
    if brightness_pct is None or brightness_pct < 5 or brightness_pct > 100:
        return False
    return True


def has_screen_off_recovery_sequence(
    parsed: ParsedLog, args: argparse.Namespace
) -> bool:
    for off_snapshot in parsed.snapshots:
        if off_snapshot.int_field("screen_off") == 0:
            continue
        if off_snapshot.int_field("idle_last_screen_off") == 0:
            continue
        if off_snapshot.int_field("idle_last_ms") <= 0:
            continue

        touch_after_off = [
            line_number
            for line_number, _ in parsed.touch_gesture_lines
            if line_number > off_snapshot.line_number
        ]
        if args.require_touch_wake and not touch_after_off:
            continue
        recovery_after_line = (
            min(touch_after_off) if args.require_touch_wake else off_snapshot.line_number
        )

        for recovery_snapshot in parsed.snapshots:
            if recovery_snapshot.line_number <= recovery_after_line:
                continue
            if recovery_snapshot.int_field("screen_off") != 0:
                continue
            if recovery_snapshot.int_field("brightness") <= 0:
                continue
            if recovery_snapshot.int_field("connect_count") < args.min_connects:
                continue
            if (
                recovery_snapshot.int_field("connect_count")
                <= off_snapshot.int_field("connect_count")
            ):
                continue
            if recovery_snapshot.int_field("disconnect_count") < args.min_disconnects:
                continue
            if recovery_snapshot.int_field("auth_successes") < args.min_auth_successes:
                continue
            if (
                recovery_snapshot.int_field("auth_successes")
                <= off_snapshot.int_field("auth_successes")
            ):
                continue
            if args.require_authenticated and recovery_snapshot.int_field("auth") == 0:
                continue
            return True
    return False


def has_complete_ios_ble_session_snapshot(
    parsed: ParsedLog, args: argparse.Namespace
) -> bool:
    for snapshot in parsed.snapshots:
        if snapshot.int_field("uptime_ms") < args.min_uptime_ms:
            continue
        if args.require_authenticated and snapshot.int_field("auth") == 0:
            continue
        if snapshot.int_field("connect_count") < args.min_connects:
            continue
        if snapshot.int_field("auth_successes") < args.min_auth_successes:
            continue
        if snapshot.int_field("nav_packets") < args.min_nav_packets:
            continue
        if snapshot.int_field("route_packets") < args.min_route_packets:
            continue
        if snapshot.int_field("gps_packets") < args.min_gps_packets:
            continue
        if snapshot.int_field("settings_packets") < args.min_settings_packets:
            continue
        if snapshot.int_field("route_stored_pts") < args.min_route_stored_points:
            continue
        if snapshot.int_field("route_total_m") < args.min_route_total_meters:
            continue
        return True
    return False


def has_complete_ios_ble_reconnect_snapshot(
    parsed: ParsedLog, args: argparse.Namespace
) -> bool:
    for snapshot in parsed.snapshots:
        if args.require_authenticated and snapshot.int_field("auth") == 0:
            continue
        if snapshot.int_field("connect_count") < args.min_connects:
            continue
        if snapshot.int_field("disconnect_count") < args.min_disconnects:
            continue
        if snapshot.int_field("auth_successes") < args.min_auth_successes:
            continue
        if snapshot.int_field("session_nav_packets") < 1:
            continue
        if (
            snapshot.int_field("session_route_packets") < 1
            and snapshot.int_field("session_route_duplicates") < 1
        ):
            continue
        if snapshot.int_field("session_gps_packets") < 1:
            continue
        if snapshot.int_field("session_settings_packets") < 1:
            continue
        if snapshot.int_field("route_stored_pts") < args.min_route_stored_points:
            continue
        if snapshot.int_field("route_total_m") < args.min_route_total_meters:
            continue
        ordered_reconnect_seen = False
        for earlier in parsed.snapshots:
            if earlier.line_number >= snapshot.line_number:
                continue
            if earlier.int_field("connect_count") >= snapshot.int_field("connect_count"):
                continue
            if earlier.int_field("disconnect_count") >= snapshot.int_field(
                "disconnect_count"
            ):
                continue
            if earlier.int_field("auth_successes") >= snapshot.int_field(
                "auth_successes"
            ):
                continue
            ordered_reconnect_seen = True
            break
        if not ordered_reconnect_seen:
            continue
        return True
    return False


def has_complete_ios_ble_ride_snapshot(
    parsed: ParsedLog, args: argparse.Namespace
) -> bool:
    for snapshot in parsed.snapshots:
        if snapshot.int_field("uptime_ms") < args.min_uptime_ms:
            continue
        if args.require_authenticated and snapshot.int_field("auth") == 0:
            continue
        if snapshot.int_field("connect_count") < args.min_connects:
            continue
        if snapshot.int_field("auth_successes") < args.min_auth_successes:
            continue
        if snapshot.int_field("nav_packets") < args.min_nav_packets:
            continue
        if snapshot.int_field("route_packets") < args.min_route_packets:
            continue
        if snapshot.int_field("gps_packets") < args.min_gps_packets:
            continue
        if snapshot.int_field("gps_fresh") == 0:
            continue
        if snapshot.int_field("settings_packets") < args.min_settings_packets:
            continue
        if snapshot.int_field("route_stored_pts") < args.min_route_stored_points:
            continue
        if snapshot.int_field("route_total_m") < args.min_route_total_meters:
            continue
        if (
            args.max_render_ms is not None
            and (
                "render_max_ms" not in snapshot.fields
                or snapshot.int_field("render_max_ms") > args.max_render_ms
            )
        ):
            continue
        return True
    return False


def has_complete_map_candidate_snapshot(
    parsed: ParsedLog, args: argparse.Namespace
) -> bool:
    for snapshot in parsed.snapshots:
        if snapshot.fields.get("map_decision") != "candidate":
            continue
        if (
            snapshot.int_field("map_has_probe") == 0
            and snapshot.int_field("map_probes") == 0
        ):
            continue
        if args.require_map_sd and snapshot.int_field("map_sd") == 0:
            continue
        if args.require_map_found and snapshot.int_field("map_found") == 0:
            continue
        if args.require_map_from_gps and snapshot.int_field("map_from_gps") == 0:
            continue
        if args.require_map_enabled and snapshot.int_field("map_enabled") == 0:
            continue
        if snapshot.int_field("map_renders") < args.min_map_renders:
            continue
        if snapshot.int_field("map_render_segments") < args.min_map_render_segments:
            continue
        if (
            args.require_map_render_valid
            and snapshot.int_field("map_render_valid") == 0
        ):
            continue
        if (
            args.max_map_scan_ms is not None
            and (
                "map_scan_ms" not in snapshot.fields
                or snapshot.int_field("map_scan_ms") > args.max_map_scan_ms
            )
        ):
            continue
        if (
            args.max_map_render_ms is not None
            and (
                "map_render_ms" not in snapshot.fields
                or snapshot.int_field("map_render_ms") > args.max_map_render_ms
            )
        ):
            continue
        if (
            args.fail_map_render_budget
            and snapshot.int_field("map_render_budget") != 0
        ):
            continue
        return True
    return False


def validate(parsed: ParsedLog, args: argparse.Namespace) -> list[str]:
    issues: list[str] = []
    if parsed.boot_heap is None:
        issues.append("missing boot free_heap_approx line")
    elif parsed.boot_heap < args.min_free_heap:
        issues.append(
            f"boot free_heap_approx {parsed.boot_heap} below minimum {args.min_free_heap}"
        )

    if parsed.reset_reason is None:
        issues.append("missing reset_reason/reset_flags line")
    elif parsed.reset_flags:
        flags = {flag.strip() for flag in parsed.reset_flags.split(",") if flag.strip()}
        bad_flags = sorted(flags & BAD_RESET_FLAGS)
        if bad_flags and not args.allow_bad_reset_flags:
            issues.append(f"bad reset flag(s): {','.join(bad_flags)}")

    if len(parsed.snapshots) < args.min_snapshots:
        issues.append(
            f"diagnostic snapshots {len(parsed.snapshots)} below minimum {args.min_snapshots}"
        )

    if parsed.max_uptime_ms < args.min_uptime_ms:
        issues.append(
            f"max uptime {parsed.max_uptime_ms} ms below minimum {args.min_uptime_ms} ms"
        )

    counters = {
        "connect_count": args.min_connects,
        "disconnect_count": args.min_disconnects,
        "auth_challenges": args.min_auth_challenges,
        "auth_successes": args.min_auth_successes,
        "unauth_rejects": args.min_unauth_rejects,
        "gps_packets": args.min_gps_packets,
        "nav_packets": args.min_nav_packets,
        "route_packets": args.min_route_packets,
        "route_duplicates": args.min_route_duplicates,
        "settings_packets": args.min_settings_packets,
        "device_commands": args.min_device_commands,
        "ble_resets": args.min_ble_resets,
        "idle_calls": args.min_idle_calls,
    }
    for field, minimum in counters.items():
        observed = latest_counter(parsed, field)
        if observed < minimum:
            issues.append(f"{field} {observed} below minimum {minimum}")

    max_route_stored_points = latest_counter(parsed, "route_stored_pts")
    if max_route_stored_points < args.min_route_stored_points:
        issues.append(
            "route_stored_pts "
            f"{max_route_stored_points} below minimum {args.min_route_stored_points}"
        )

    max_route_total_m = latest_counter(parsed, "route_total_m")
    if max_route_total_m < args.min_route_total_meters:
        issues.append(
            f"route_total_m {max_route_total_m} below minimum "
            f"{args.min_route_total_meters}"
        )

    min_snapshot_heap = min(
        (snapshot.int_field("free_heap_approx") for snapshot in parsed.snapshots),
        default=0,
    )
    if parsed.snapshots and min_snapshot_heap < args.min_free_heap:
        issues.append(
            f"minimum snapshot free_heap_approx {min_snapshot_heap} below {args.min_free_heap}"
        )

    if args.max_render_ms is not None:
        render_values = [
            snapshot.int_field("render_max_ms")
            for snapshot in parsed.snapshots
            if "render_max_ms" in snapshot.fields
        ]
        if not render_values:
            issues.append("missing diagnostic field: render_max_ms")
        elif max(render_values) > args.max_render_ms:
            render_max = max(render_values)
            issues.append(f"render_max_ms {render_max} exceeds {args.max_render_ms}")

    if args.require_authenticated:
        authenticated_seen = any(
            snapshot.int_field("auth") != 0 for snapshot in parsed.snapshots
        )
        if not authenticated_seen:
            issues.append("missing authenticated BLE session evidence")

    if args.forbid_simulation and parsed.simulation_lines:
        line_number, line = parsed.simulation_lines[0]
        issues.append(f"simulation session evidence present at line {line_number}: {line}")

    if args.require_battery_calibration and not parsed.battery_calibration_lines:
        issues.append("missing battery calibration command evidence")

    if args.require_touch_wake and not parsed.touch_gesture_lines:
        issues.append("missing touch wake gesture evidence")

    if args.profile == "power-runtime":
        required_evidence_fields = (
            "runtime_minutes",
            "thermal_max_c",
            "start_battery_mv",
            "end_battery_mv",
            "brightness_pct",
        )
        for field in required_evidence_fields:
            if evidence_int(parsed, field) is None:
                issues.append(f"missing numeric evidence field: {field}")
        runtime_minutes = evidence_int(parsed, "runtime_minutes")
        if (
            runtime_minutes is not None
            and runtime_minutes < args.min_runtime_minutes
        ):
            issues.append(
                f"runtime_minutes {runtime_minutes} below minimum "
                f"{args.min_runtime_minutes}"
            )
        thermal_max_c = evidence_int(parsed, "thermal_max_c")
        if thermal_max_c is not None and thermal_max_c > args.max_thermal_c:
            issues.append(f"thermal_max_c {thermal_max_c} exceeds {args.max_thermal_c}")
        if thermal_max_c is not None and thermal_max_c < 0:
            issues.append(f"thermal_max_c {thermal_max_c} below 0")
        start_battery_mv = evidence_int(parsed, "start_battery_mv")
        end_battery_mv = evidence_int(parsed, "end_battery_mv")
        if start_battery_mv is not None and (
            start_battery_mv < args.min_battery_mv
            or start_battery_mv > args.max_battery_mv
        ):
            issues.append(
                f"start_battery_mv {start_battery_mv} outside "
                f"{args.min_battery_mv}..{args.max_battery_mv}"
            )
        if end_battery_mv is not None and (
            end_battery_mv < args.min_battery_mv
            or end_battery_mv > args.max_battery_mv
        ):
            issues.append(
                f"end_battery_mv {end_battery_mv} outside "
                f"{args.min_battery_mv}..{args.max_battery_mv}"
            )
        if start_battery_mv is not None and end_battery_mv is not None:
            voltage_drop = start_battery_mv - end_battery_mv
            if voltage_drop < args.min_voltage_drop_mv:
                issues.append(
                    f"battery voltage drop {voltage_drop} below minimum "
                    f"{args.min_voltage_drop_mv}"
                )
        if (
            start_battery_mv is not None
            and end_battery_mv is not None
            and args.max_runtime_voltage_delta_mv is not None
        ):
            battery_values = numeric_values(parsed, "battery_mv")
            if battery_values:
                observed_start_mv = max(battery_values)
                observed_end_mv = min(battery_values)
                if (
                    abs(observed_start_mv - start_battery_mv)
                    > args.max_runtime_voltage_delta_mv
                ):
                    issues.append(
                        "start_battery_mv "
                        f"{start_battery_mv} differs from diagnostic maximum "
                        f"{observed_start_mv} by more than "
                        f"{args.max_runtime_voltage_delta_mv}"
                    )
                if (
                    abs(observed_end_mv - end_battery_mv)
                    > args.max_runtime_voltage_delta_mv
                ):
                    issues.append(
                        "end_battery_mv "
                        f"{end_battery_mv} differs from diagnostic minimum "
                        f"{observed_end_mv} by more than "
                        f"{args.max_runtime_voltage_delta_mv}"
                    )
        brightness_pct = evidence_int(parsed, "brightness_pct")
        if brightness_pct is not None and (
            brightness_pct < 5 or brightness_pct > 100
        ):
            issues.append(f"brightness_pct {brightness_pct} outside 5..100")

    idle_total_ms = latest_counter(parsed, "idle_total_ms")
    if idle_total_ms < args.min_idle_total_ms:
        issues.append(
            f"idle_total_ms {idle_total_ms} below minimum {args.min_idle_total_ms}"
        )

    idle_max_ms = latest_counter(parsed, "idle_max_ms")
    if idle_max_ms < args.min_idle_max_ms:
        issues.append(
            f"idle_max_ms {idle_max_ms} below minimum {args.min_idle_max_ms}"
        )

    if args.require_diagnostic_field:
        observed_fields = set()
        for snapshot in parsed.snapshots:
            observed_fields.update(snapshot.fields.keys())
        for field in args.require_diagnostic_field:
            if field not in observed_fields:
                issues.append(f"missing diagnostic field: {field}")

    if args.require_screen_off:
        screen_off_seen = any(
            snapshot.int_field("screen_off") != 0 for snapshot in parsed.snapshots
        )
        if not screen_off_seen:
            issues.append("missing screen_off evidence")

    if args.require_screen_off_idle:
        screen_off_idle_seen = any(
            snapshot.int_field("screen_off") != 0
            and snapshot.int_field("idle_last_screen_off") != 0
            and snapshot.int_field("idle_last_ms") > 0
            for snapshot in parsed.snapshots
        )
        if not screen_off_idle_seen:
            issues.append("missing screen-off idle delay evidence")

    if args.require_screen_on_after_off:
        saw_screen_off = False
        recovered = False
        for snapshot in parsed.snapshots:
            if snapshot.int_field("screen_off") != 0:
                saw_screen_off = True
            elif saw_screen_off and snapshot.int_field("brightness") > 0:
                recovered = True
                break
        if not saw_screen_off:
            issues.append("missing screen_off evidence before recovery")
        elif not recovered:
            issues.append("missing screen-on recovery after screen_off")

    if args.min_brightness is not None or args.max_brightness is not None:
        brightness_values = [
            snapshot.int_field("brightness")
            for snapshot in parsed.snapshots
            if "brightness" in snapshot.fields
        ]
        if not brightness_values:
            issues.append("missing diagnostic field: brightness")
        else:
            brightness_max = max(brightness_values)
            if (
                args.min_brightness is not None
                and brightness_max < args.min_brightness
            ):
                issues.append(
                    f"brightness maximum {brightness_max} below {args.min_brightness}"
                )
            if (
                args.max_brightness is not None
                and brightness_max > args.max_brightness
            ):
                issues.append(
                    f"brightness maximum {brightness_max} exceeds {args.max_brightness}"
                )

    check_numeric_range(
        issues,
        parsed,
        "battery_mv",
        args.min_battery_mv,
        args.max_battery_mv,
    )
    check_numeric_range(
        issues,
        parsed,
        "battery_pct",
        args.min_battery_pct,
        args.max_battery_pct,
    )
    check_numeric_range(
        issues,
        parsed,
        "battery_scale_permille",
        args.min_battery_scale,
        args.max_battery_scale,
    )

    if args.require_rtc_present:
        rtc_present_seen = any(
            snapshot.int_field("rtc_present") != 0 for snapshot in parsed.snapshots
        )
        if not rtc_present_seen:
            issues.append("missing rtc_present evidence")

    if args.require_rtc_valid:
        rtc_valid_seen = any(
            snapshot.int_field("rtc_valid") != 0 for snapshot in parsed.snapshots
        )
        if not rtc_valid_seen:
            issues.append("missing rtc_valid evidence")

    if args.require_rtc_source:
        allowed_sources = set(args.require_rtc_source)
        observed_sources = [
            snapshot.fields.get("rtc_source", "")
            for snapshot in parsed.snapshots
            if snapshot.fields.get("rtc_source")
        ]
        if not any(source in allowed_sources for source in observed_sources):
            issues.append(
                "rtc_source did not include allowed value(s): "
                f"{','.join(sorted(allowed_sources))}"
            )

    if (
        args.profile == "power-rtc-calibration"
        and not has_complete_power_rtc_snapshot(parsed, args)
    ):
        issues.append(
            "missing complete power/RTC calibration evidence snapshot after BATCAL"
        )

    if args.profile == "power-runtime" and not has_complete_power_rtc_snapshot(
        parsed, args
    ):
        issues.append("missing complete calibrated battery evidence snapshot after BATCAL")

    if (
        args.profile == "ios-ble-session"
        and not has_complete_ios_ble_session_snapshot(parsed, args)
    ):
        issues.append("missing complete authenticated iOS BLE evidence snapshot")

    if (
        args.profile == "ios-ble-reconnect"
        and not has_complete_ios_ble_reconnect_snapshot(parsed, args)
    ):
        issues.append("missing complete post-reconnect iOS BLE evidence snapshot")

    if (
        args.profile == "ios-ble-ride-60"
        and not has_complete_ios_ble_ride_snapshot(parsed, args)
    ):
        issues.append("missing complete 60-minute iOS BLE ride evidence snapshot")

    if args.max_map_scan_ms is not None:
        map_scan_values = numeric_values(parsed, "map_scan_ms")
        if not map_scan_values:
            issues.append("missing numeric diagnostic field: map_scan_ms")
        else:
            map_scan_max = max(map_scan_values)
            if map_scan_max > args.max_map_scan_ms:
                issues.append(
                    f"map_scan_ms {map_scan_max} exceeds {args.max_map_scan_ms}"
                )

    if args.min_map_probes:
        map_probes = latest_counter(parsed, "map_probes")
        if map_probes < args.min_map_probes:
            issues.append(f"map_probes {map_probes} below minimum {args.min_map_probes}")

    if args.require_map_probe:
        has_map_probe = any(
            snapshot.int_field("map_has_probe") != 0
            or snapshot.int_field("map_probes") != 0
            for snapshot in parsed.snapshots
        )
        if not has_map_probe:
            issues.append("missing map-lite probe evidence")

    if args.require_map_enabled:
        map_enabled_seen = any(
            snapshot.int_field("map_enabled") != 0 for snapshot in parsed.snapshots
        )
        if not map_enabled_seen:
            issues.append("missing map-lite experiment enable evidence")

    if args.require_map_sd:
        map_sd_seen = any(
            snapshot.int_field("map_sd") != 0 for snapshot in parsed.snapshots
        )
        if not map_sd_seen:
            issues.append("missing map-lite SD-ready evidence")

    if args.require_map_found:
        map_found_seen = any(
            snapshot.int_field("map_found") != 0 for snapshot in parsed.snapshots
        )
        if not map_found_seen:
            issues.append("missing map-lite found-block evidence")

    if args.require_map_from_gps:
        map_from_gps_seen = any(
            snapshot.int_field("map_from_gps") != 0 for snapshot in parsed.snapshots
        )
        if not map_from_gps_seen:
            issues.append("missing GPS-driven map-lite probe evidence")

    if args.require_map_decision:
        allowed = set(args.require_map_decision)
        observed = [
            snapshot.fields.get("map_decision", "")
            for snapshot in parsed.snapshots
            if snapshot.fields.get("map_decision")
        ]
        if not any(decision in allowed for decision in observed):
            issues.append(
                "map_decision did not include allowed value(s): "
                f"{','.join(sorted(allowed))}"
            )

    if args.min_map_renders:
        map_renders = latest_counter(parsed, "map_renders")
        if map_renders < args.min_map_renders:
            issues.append(
                f"map_renders {map_renders} below minimum {args.min_map_renders}"
            )

    if args.min_map_render_segments:
        map_render_segments = latest_counter(parsed, "map_render_segments")
        if map_render_segments < args.min_map_render_segments:
            issues.append(
                "map_render_segments "
                f"{map_render_segments} below minimum "
                f"{args.min_map_render_segments}"
            )

    if args.max_map_render_ms is not None:
        map_render_values = numeric_values(parsed, "map_render_ms")
        if not map_render_values:
            issues.append("missing numeric diagnostic field: map_render_ms")
        else:
            map_render_max = max(map_render_values)
            if map_render_max > args.max_map_render_ms:
                issues.append(
                    f"map_render_ms {map_render_max} exceeds {args.max_map_render_ms}"
                )

    if args.require_map_render_valid:
        map_render_valid_seen = any(
            snapshot.int_field("map_render_valid") != 0
            for snapshot in parsed.snapshots
        )
        if not map_render_valid_seen:
            issues.append("missing valid map-lite render evidence")

    if args.fail_map_render_budget:
        budget_exceeded = any(
            snapshot.int_field("map_render_budget") != 0
            for snapshot in parsed.snapshots
        )
        if budget_exceeded:
            issues.append("map_render_budget was exceeded")

    if args.profile == "map-lite-candidate" and not has_complete_map_candidate_snapshot(
        parsed, args
    ):
        issues.append("missing complete map-lite candidate evidence snapshot")

    if args.profile == "power-runtime" and not has_power_runtime_evidence(
        parsed, args
    ):
        issues.append("missing complete measured power runtime evidence")

    if args.profile == "power-screen-off-recovery" and not (
        has_screen_off_recovery_sequence(parsed, args)
    ):
        issues.append("missing complete screen-off touch and BLE recovery sequence")

    for line_number, line in parsed.forbidden_lines[: args.max_reported_lines]:
        issues.append(f"forbidden log line {line_number}: {line}")
    extra_forbidden = len(parsed.forbidden_lines) - args.max_reported_lines
    if extra_forbidden > 0:
        issues.append(f"{extra_forbidden} additional forbidden log line(s)")

    return issues


def print_summary(parsed: ParsedLog, issues: list[str], output: TextIO) -> None:
    latest = parsed.snapshots[-1] if parsed.snapshots else None
    print("Serial log summary:", file=output)
    print(f"  boot_free_heap={parsed.boot_heap}", file=output)
    print(f"  reset_reason={parsed.reset_reason} flags={parsed.reset_flags}", file=output)
    print(f"  max_uptime_ms={parsed.max_uptime_ms}", file=output)
    print(f"  snapshots={len(parsed.snapshots)}", file=output)
    print(f"  simulation_lines={len(parsed.simulation_lines)}", file=output)
    print(
        f"  battery_calibration_lines={len(parsed.battery_calibration_lines)}",
        file=output,
    )
    print(f"  evidence_lines={len(parsed.evidence_lines)}", file=output)
    print(f"  touch_gesture_lines={len(parsed.touch_gesture_lines)}", file=output)
    if latest is not None:
        print(
            "  latest="
            f"line:{latest.line_number} label:{latest.label} "
            f"connects:{latest.int_field('connect_count')} "
            f"disconnects:{latest.int_field('disconnect_count')} "
            f"auth:{latest.int_field('auth')} "
            f"auth_successes:{latest.int_field('auth_successes')} "
            f"gps:{latest.int_field('gps_packets')} "
            f"nav:{latest.int_field('nav_packets')} "
            f"route:{latest.int_field('route_packets')} "
            f"route_dup:{latest.int_field('route_duplicates')} "
            f"route_total_m:{latest.int_field('route_total_m')} "
            f"settings:{latest.int_field('settings_packets')} "
            f"session_nav:{latest.int_field('session_nav_packets')} "
            f"session_route:{latest.int_field('session_route_packets')} "
            f"session_route_dup:{latest.int_field('session_route_duplicates')} "
            f"session_gps:{latest.int_field('session_gps_packets')} "
            f"session_settings:{latest.int_field('session_settings_packets')} "
            f"heap:{latest.int_field('free_heap_approx')} "
            f"brightness:{latest.int_field('brightness')} "
            f"screen_off:{latest.int_field('screen_off')} "
            f"idle_calls:{latest.int_field('idle_calls')} "
            f"idle_total:{latest.int_field('idle_total_ms')} "
            f"idle_last:{latest.int_field('idle_last_ms')} "
            f"idle_screen_off:{latest.int_field('idle_last_screen_off')} "
            f"battery_mv:{latest.fields.get('battery_mv', 'missing')} "
            f"battery_pct:{latest.fields.get('battery_pct', 'missing')} "
            f"battery_scale:{latest.fields.get('battery_scale_permille', 'missing')} "
            f"rtc_present:{latest.fields.get('rtc_present', 'missing')} "
            f"rtc_valid:{latest.fields.get('rtc_valid', 'missing')} "
            f"rtc_source:{latest.fields.get('rtc_source', 'missing')} "
            f"render_max:{latest.int_field('render_max_ms')} "
            f"map_sd:{latest.fields.get('map_sd', 'missing')} "
            f"map_from_gps:{latest.fields.get('map_from_gps', 'missing')} "
            f"map_found:{latest.fields.get('map_found', 'missing')} "
            f"map_decision:{latest.fields.get('map_decision', 'missing')} "
            f"map_scan:{latest.int_field('map_scan_ms')} "
            f"map_render_valid:{latest.fields.get('map_render_valid', 'missing')} "
            f"map_render:{latest.int_field('map_render_ms')} "
            f"map_render_segments:{latest.int_field('map_render_segments')}",
            file=output,
        )
    if issues:
        print("FAIL:", file=output)
        for issue in issues:
            print(f"  - {issue}", file=output)
    else:
        print("PASS", file=output)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate XIAO Round Display firmware serial diagnostics logs."
    )
    parser.add_argument("log", help="serial log path, or '-' for stdin")
    parser.add_argument(
        "--profile",
        choices=[
            "generic",
            "serial-soak-60",
            "map-lite-candidate",
            "ios-ble-session",
            "ios-ble-reconnect",
            "ios-ble-ride-60",
            "power-rtc-calibration",
            "power-runtime",
            "power-screen-off-recovery",
        ],
        default="generic",
        help="preset validation profile",
    )
    parser.add_argument("--min-snapshots", type=int_arg, default=1)
    parser.add_argument("--min-uptime-ms", type=int_arg, default=0)
    parser.add_argument("--min-free-heap", type=int_arg, default=1)
    parser.add_argument("--min-connects", type=int_arg, default=0)
    parser.add_argument("--min-disconnects", type=int_arg, default=0)
    parser.add_argument("--min-auth-challenges", type=int_arg, default=0)
    parser.add_argument("--min-auth-successes", type=int_arg, default=0)
    parser.add_argument("--min-unauth-rejects", type=int_arg, default=0)
    parser.add_argument("--min-gps-packets", type=int_arg, default=0)
    parser.add_argument("--min-nav-packets", type=int_arg, default=0)
    parser.add_argument("--min-route-packets", type=int_arg, default=0)
    parser.add_argument("--min-route-duplicates", type=int_arg, default=0)
    parser.add_argument("--min-settings-packets", type=int_arg, default=0)
    parser.add_argument("--min-device-commands", type=int_arg, default=0)
    parser.add_argument("--min-ble-resets", type=int_arg, default=0)
    parser.add_argument("--min-idle-calls", type=int_arg, default=0)
    parser.add_argument("--min-idle-total-ms", type=int_arg, default=0)
    parser.add_argument("--min-idle-max-ms", type=int_arg, default=0)
    parser.add_argument("--min-route-stored-points", type=int_arg, default=0)
    parser.add_argument("--min-route-total-meters", type=int_arg, default=0)
    parser.add_argument("--max-render-ms", type=int_arg)
    parser.add_argument("--require-authenticated", action="store_true")
    parser.add_argument("--forbid-simulation", action="store_true")
    parser.add_argument(
        "--require-diagnostic-field",
        action="append",
        help="require at least one Diagnostics snapshot to include this key",
    )
    parser.add_argument("--min-brightness", type=int_arg)
    parser.add_argument("--max-brightness", type=int_arg)
    parser.add_argument("--min-battery-mv", type=int_arg)
    parser.add_argument("--max-battery-mv", type=int_arg)
    parser.add_argument("--min-battery-pct", type=int_arg)
    parser.add_argument("--max-battery-pct", type=int_arg)
    parser.add_argument("--min-battery-scale", type=int_arg)
    parser.add_argument("--max-battery-scale", type=int_arg)
    parser.add_argument("--min-runtime-minutes", type=int_arg)
    parser.add_argument("--max-thermal-c", type=int_arg)
    parser.add_argument("--min-voltage-drop-mv", type=int_arg)
    parser.add_argument("--max-runtime-voltage-delta-mv", type=int_arg)
    parser.add_argument("--require-rtc-present", action="store_true")
    parser.add_argument("--require-rtc-valid", action="store_true")
    parser.add_argument(
        "--require-rtc-source",
        action="append",
        choices=["rtc", "ble", "unknown"],
        help=(
            "require at least one rtc_source with this value; repeat to allow "
            "multiple sources"
        ),
    )
    parser.add_argument("--require-screen-off", action="store_true")
    parser.add_argument("--require-screen-off-idle", action="store_true")
    parser.add_argument("--require-screen-on-after-off", action="store_true")
    parser.add_argument("--require-touch-wake", action="store_true")
    parser.add_argument("--require-battery-calibration", action="store_true")
    parser.add_argument("--max-map-scan-ms", type=int_arg)
    parser.add_argument("--min-map-probes", type=int_arg, default=0)
    parser.add_argument("--require-map-probe", action="store_true")
    parser.add_argument(
        "--require-map-decision",
        action="append",
        choices=["candidate", "no-data", "too-slow", "too-complex", "invalid"],
        help=(
            "require at least one map_decision with this value; repeat to allow "
            "multiple outcomes"
        ),
    )
    parser.add_argument("--min-map-renders", type=int_arg, default=0)
    parser.add_argument("--max-map-render-ms", type=int_arg)
    parser.add_argument("--min-map-render-segments", type=int_arg, default=0)
    parser.add_argument("--require-map-sd", action="store_true")
    parser.add_argument("--require-map-found", action="store_true")
    parser.add_argument("--require-map-from-gps", action="store_true")
    parser.add_argument("--require-map-enabled", action="store_true")
    parser.add_argument("--require-map-render-valid", action="store_true")
    parser.add_argument("--fail-map-render-budget", action="store_true")
    parser.add_argument("--allow-rejections", action="store_true")
    parser.add_argument("--allow-bad-reset-flags", action="store_true")
    parser.add_argument("--max-reported-lines", type=int_arg, default=5)
    args = parser.parse_args(argv)
    apply_profile(args)
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    parsed = parse_log(read_lines(args.log), allow_rejections=args.allow_rejections)
    issues = validate(parsed, args)
    print_summary(parsed, issues, sys.stdout)
    return 1 if issues else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
