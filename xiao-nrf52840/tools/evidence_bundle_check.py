#!/usr/bin/env python3
"""Validate a directory of XIAO Round Display hardware evidence logs."""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import hardware_bringup_check
import serial_log_check


@dataclass(frozen=True)
class BundleCheck:
    key: str
    filename: str
    description: str
    profile: str | None = None
    args: tuple[str, ...] = ()


@dataclass(frozen=True)
class CheckResult:
    key: str
    filename: str
    passed: bool
    issues: tuple[str, ...]


SERIAL_CHECKS: tuple[BundleCheck, ...] = (
    BundleCheck(
        "ios-ble-session",
        "ios-ble-session.log",
        "real iOS authenticated BLE write session",
        "ios-ble-session",
    ),
    BundleCheck(
        "ios-ble-reconnect",
        "ios-ble-reconnect.log",
        "real iOS reconnect write session",
        "ios-ble-reconnect",
    ),
    BundleCheck(
        "ios-ble-ride-60",
        "ios-ble-ride-60.log",
        "real iOS 60-minute ride",
        "ios-ble-ride-60",
    ),
    BundleCheck(
        "serial-soak-60",
        "serial-soak-60.log",
        "firmware-side serial soak",
        "serial-soak-60",
    ),
    BundleCheck(
        "route-duplicate",
        "route-duplicate.log",
        "duplicate route debounce counter evidence",
        args=("--min-route-packets", "1", "--min-route-duplicates", "1"),
    ),
    BundleCheck(
        "power-rtc-calibration",
        "power-rtc-calibration.log",
        "battery calibration and RTC readback",
        "power-rtc-calibration",
    ),
    BundleCheck(
        "power-runtime",
        "power-runtime.log",
        "measured runtime and thermal evidence",
        "power-runtime",
    ),
    BundleCheck(
        "power-screen-off-recovery",
        "power-screen-off-recovery.log",
        "screen-off touch wake and BLE reconnect",
        "power-screen-off-recovery",
    ),
)

MAP_LITE_DECISIONS = {"candidate", "no-data", "too-slow", "too-complex", "invalid"}


def _read_log(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines()


def validate_hardware_bringup(root: Path) -> CheckResult:
    filename = "hardware-bringup.log"
    path = root / filename
    if not path.exists():
        return CheckResult(
            key="hardware-bringup",
            filename=filename,
            passed=False,
            issues=(f"missing required log: {filename}",),
        )

    lines = _read_log(path)
    found = hardware_bringup_check.find_evidence(lines)
    forbidden = hardware_bringup_check.find_forbidden_board_lines(lines)
    issues: list[str] = []
    for rule in hardware_bringup_check.RULES:
        if rule.key not in found:
            issues.append(f"missing {rule.label} ({rule.key})")
    for line_number, line in forbidden:
        issues.append(f"wrong board evidence at line {line_number}: {line}")
    return CheckResult(
        key="hardware-bringup",
        filename=filename,
        passed=not issues,
        issues=tuple(issues),
    )


def validate_serial_profile(root: Path, check: BundleCheck) -> CheckResult:
    path = root / check.filename
    if not path.exists():
        return CheckResult(
            key=check.key,
            filename=check.filename,
            passed=False,
            issues=(f"missing required log: {check.filename}",),
        )

    profile_args = ["--profile", check.profile] if check.profile else []
    args = serial_log_check.parse_args(["-", *profile_args, *check.args])
    parsed = serial_log_check.parse_log(_read_log(path), args.allow_rejections)
    issues = serial_log_check.validate(parsed, args)
    return CheckResult(
        key=check.key,
        filename=check.filename,
        passed=not issues,
        issues=tuple(issues),
    )


def observed_map_lite_decision(parsed: serial_log_check.ParsedLog) -> str | None:
    for snapshot in reversed(parsed.snapshots):
        decision = snapshot.fields.get("map_decision")
        if decision in MAP_LITE_DECISIONS:
            return decision
    return None


def add_map_lite_measurement_issues(
    parsed: serial_log_check.ParsedLog, issues: list[str]
) -> None:
    for field in ("map_open_ms", "map_scan_ms"):
        if not serial_log_check.numeric_values(parsed, field):
            issues.append(f"missing numeric diagnostic field: {field}")

    if serial_log_check.latest_counter(parsed, "map_renders") > 0 and not (
        serial_log_check.numeric_values(parsed, "map_render_ms")
    ):
        issues.append("missing numeric diagnostic field: map_render_ms")


def validate_map_lite(root: Path, required: bool) -> CheckResult:
    filename = "map-lite.log"
    path = root / filename
    if not path.exists():
        if not required:
            return CheckResult(
                key="map-lite",
                filename=filename,
                passed=True,
                issues=(),
            )
        return CheckResult(
            key="map-lite",
            filename=filename,
            passed=False,
            issues=(f"missing required log: {filename}",),
        )

    base_args = serial_log_check.parse_args(["-"])
    parsed = serial_log_check.parse_log(_read_log(path), base_args.allow_rejections)
    decision = observed_map_lite_decision(parsed)
    if decision == "candidate":
        args = serial_log_check.parse_args(["-", "--profile", "map-lite-candidate"])
    elif decision in MAP_LITE_DECISIONS:
        args = serial_log_check.parse_args(
            [
                "-",
                "--require-map-probe",
                "--require-map-sd",
                "--require-map-found",
                "--require-map-from-gps",
                "--require-map-enabled",
                "--require-map-decision",
                decision,
                "--fail-map-render-budget",
            ]
        )
    else:
        return CheckResult(
            key="map-lite",
            filename=filename,
            passed=False,
            issues=("missing supported map_decision evidence",),
        )

    issues = serial_log_check.validate(parsed, args)
    add_map_lite_measurement_issues(parsed, issues)
    return CheckResult(
        key="map-lite",
        filename=filename,
        passed=not issues,
        issues=tuple(issues),
    )


def validate_bundle(root: Path, require_map_lite: bool) -> list[CheckResult]:
    results = [validate_hardware_bringup(root)]
    results.extend(validate_serial_profile(root, check) for check in SERIAL_CHECKS)
    results.append(validate_map_lite(root, require_map_lite))
    return results


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a XIAO Round Display evidence log directory."
    )
    parser.add_argument("root", help="directory containing named evidence logs")
    parser.add_argument(
        "--skip-map-lite",
        action="store_true",
        help="do not require map-lite.log when the optional experiment is not run",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = Path(args.root)
    results = validate_bundle(root, require_map_lite=not args.skip_map_lite)

    print("XIAO evidence bundle summary:")
    for result in results:
        status = "PASS" if result.passed else "FAIL"
        print(f"  {status} {result.key}: {result.filename}")
        for issue in result.issues:
            print(f"    - {issue}")

    if any(not result.passed for result in results):
        print("FAIL")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
