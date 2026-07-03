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
DEFAULT_FORBIDDEN_PATTERNS = [
    ("init-failed", re.compile(r"\binit failed\b", re.IGNORECASE)),
    ("rejection", re.compile(r"\bBLE: rejected\b", re.IGNORECASE)),
    ("line-too-long", re.compile(r"\bline too long\b", re.IGNORECASE)),
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
    if args.profile != "serial-soak-60":
        return
    args.min_snapshots = max(args.min_snapshots, 12)
    args.min_uptime_ms = max(args.min_uptime_ms, 3_600_000)
    args.min_gps_packets = max(args.min_gps_packets, 3_600)
    args.min_nav_packets = max(args.min_nav_packets, 1)
    args.min_route_packets = max(args.min_route_packets, 1)
    args.min_settings_packets = max(args.min_settings_packets, 1)
    args.min_route_stored_points = max(args.min_route_stored_points, 2)
    args.min_free_heap = max(args.min_free_heap, 1)


def latest_counter(parsed: ParsedLog, field: str) -> int:
    if not parsed.snapshots:
        return 0
    return max(snapshot.int_field(field) for snapshot in parsed.snapshots)


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
        "gps_packets": args.min_gps_packets,
        "nav_packets": args.min_nav_packets,
        "route_packets": args.min_route_packets,
        "settings_packets": args.min_settings_packets,
        "device_commands": args.min_device_commands,
        "ble_resets": args.min_ble_resets,
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

    min_snapshot_heap = min(
        (snapshot.int_field("free_heap_approx") for snapshot in parsed.snapshots),
        default=0,
    )
    if parsed.snapshots and min_snapshot_heap < args.min_free_heap:
        issues.append(
            f"minimum snapshot free_heap_approx {min_snapshot_heap} below {args.min_free_heap}"
        )

    if args.max_render_ms is not None:
        render_max = latest_counter(parsed, "render_max_ms")
        if render_max > args.max_render_ms:
            issues.append(f"render_max_ms {render_max} exceeds {args.max_render_ms}")

    if args.max_map_scan_ms is not None:
        map_scan_max = max(
            (snapshot.int_field("map_scan_ms") for snapshot in parsed.snapshots),
            default=0,
        )
        if map_scan_max > args.max_map_scan_ms:
            issues.append(f"map_scan_ms {map_scan_max} exceeds {args.max_map_scan_ms}")

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
    if latest is not None:
        print(
            "  latest="
            f"line:{latest.line_number} label:{latest.label} "
            f"gps:{latest.int_field('gps_packets')} "
            f"nav:{latest.int_field('nav_packets')} "
            f"route:{latest.int_field('route_packets')} "
            f"settings:{latest.int_field('settings_packets')} "
            f"heap:{latest.int_field('free_heap_approx')} "
            f"render_max:{latest.int_field('render_max_ms')}",
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
        choices=["generic", "serial-soak-60"],
        default="generic",
        help="preset validation profile",
    )
    parser.add_argument("--min-snapshots", type=int_arg, default=1)
    parser.add_argument("--min-uptime-ms", type=int_arg, default=0)
    parser.add_argument("--min-free-heap", type=int_arg, default=1)
    parser.add_argument("--min-gps-packets", type=int_arg, default=0)
    parser.add_argument("--min-nav-packets", type=int_arg, default=0)
    parser.add_argument("--min-route-packets", type=int_arg, default=0)
    parser.add_argument("--min-settings-packets", type=int_arg, default=0)
    parser.add_argument("--min-device-commands", type=int_arg, default=0)
    parser.add_argument("--min-ble-resets", type=int_arg, default=0)
    parser.add_argument("--min-route-stored-points", type=int_arg, default=0)
    parser.add_argument("--max-render-ms", type=int_arg)
    parser.add_argument("--max-map-scan-ms", type=int_arg)
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
