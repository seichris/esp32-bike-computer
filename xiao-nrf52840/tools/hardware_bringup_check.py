#!/usr/bin/env python3
"""Validate XIAO Round Display Milestone 0 hardware bring-up logs."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class EvidenceRule:
    key: str
    label: str
    patterns: tuple[re.Pattern[str], ...]


def compile_patterns(*patterns: str) -> tuple[re.Pattern[str], ...]:
    return tuple(re.compile(pattern, re.IGNORECASE) for pattern in patterns)


VENDOR_LINE = r"^(?!.*(?:DisplayRound:|MapLite:|RoundUi:|Diagnostics:|BLE:|SerialSim:))"
FORBIDDEN_BOARD_RE = re.compile(
    r"\bEspressif\s+USB\s+JTAG/serial\s+debug\s+unit\b|"
    r"\bUSB\s+JTAG/serial\s+debug\s+unit\b|\bESP32[- ]?S3\b|"
    r"\bESP32S3\b|\bEspressif\b|\b303A:1001\b",
    re.IGNORECASE,
)
NEGATED_FORBIDDEN_PREFIX_RE = re.compile(
    r"(?:\bnot\b|\bwithout\b|\binstead\s+of\b)\s+(?:the\s+)?$",
    re.IGNORECASE,
)


RULES: tuple[EvidenceRule, ...] = (
    EvidenceRule(
        "board_identity",
        "XIAO nRF52840 board identity",
        compile_patterns(
            r"\b(Seeed\s+Studio\s+)?XIAO\b.*\bnRF52840\b",
            r"\bnRF52840\b.*\b(Seeed\s+Studio\s+)?XIAO\b",
            r"\bEVIDENCE\s+board_identity\s*=\s*(pass|ok|true|1)\b",
        ),
    ),
    EvidenceRule(
        "vendor_display",
        "vendor display init",
        compile_patterns(
            VENDOR_LINE + r".*\bdisplay\b.*\b(init|begin|ready|ok|pass|success|done)",
            VENDOR_LINE
            + r".*\b(lcd|tft|gc9a01|screen)\b.*"
            + r"\b(init|begin|ready|ok|pass|success|done)",
        ),
    ),
    EvidenceRule(
        "vendor_touch",
        "vendor touch event",
        compile_patterns(
            VENDOR_LINE + r".*\btouch\b.*\b(event|press|pressed|tap|detected|x=|x:|ok|pass)",
            VENDOR_LINE + r".*\b(chsc|cst|touch)\b.*\b(read|point|coordinate)",
        ),
    ),
    EvidenceRule(
        "vendor_rtc",
        "vendor RTC read",
        compile_patterns(
            VENDOR_LINE + r".*\b(rtc|pcf8563|pcf85063)\b.*\b(found|read|time|valid|ok|pass)",
            VENDOR_LINE + r".*\btime\b.*\b(rtc|pcf8563|pcf85063)",
        ),
    ),
    EvidenceRule(
        "vendor_battery",
        "vendor battery ADC read",
        compile_patterns(
            VENDOR_LINE + r".*\b(battery|bat|adc|a0)\b.*\b(mv|volt|voltage|raw|read|ok|pass)",
            VENDOR_LINE + r".*\b\d+\s*mV\b",
        ),
    ),
    EvidenceRule(
        "vendor_sd",
        "vendor microSD read/write",
        compile_patterns(
            VENDOR_LINE
            + r".*\b(sd|microsd|tf)\b.*"
            + r"\b(mount|begin|ready|open|read|write|list|ok|pass|success)",
            VENDOR_LINE + r".*\b(card|fat32)\b.*\b(read|write|mount|ready|ok|pass)",
        ),
    ),
    EvidenceRule(
        "repo_sdls",
        "repo SDLS directory listing",
        compile_patterns(
            r"MapLite: SD list path=.*\bentries=\d+.*\berror=0",
            r"MapLite: sd entry name=",
        ),
    ),
    EvidenceRule(
        "repo_lcd_init",
        "repo LCD init",
        compile_patterns(
            r"DisplayRound: Seeed_GFX GC9A01 init complete",
        ),
    ),
    EvidenceRule(
        "repo_lcd_boot",
        "repo boot/status LCD drawing",
        compile_patterns(
            r"DisplayRound: boot screen drawn",
            r"DisplayRound: status: ",
        ),
    ),
    EvidenceRule(
        "repo_lcd_map",
        "repo route/map LCD primitives",
        compile_patterns(
            r"DisplayRound: map frame .* lines=[1-9]\d* .*elapsed_ms=\d+",
        ),
    ),
    EvidenceRule(
        "repo_touch_start",
        "repo touch coordinates",
        compile_patterns(
            r"RoundUi: touch start x=\d+ y=\d+",
        ),
    ),
    EvidenceRule(
        "repo_touch_gesture",
        "repo touch gesture",
        compile_patterns(
            r"RoundUi: gesture=(tap|long|left|right|up|down)",
        ),
    ),
)


RULE_BY_KEY = {rule.key: rule for rule in RULES}


def read_lines(path: str) -> list[str]:
    if path == "-":
        return [line.rstrip("\n") for line in sys.stdin]
    return Path(path).read_text(encoding="utf-8").splitlines()


def evidence_marker(line: str) -> str | None:
    match = re.search(
        r"\bEVIDENCE\s+([A-Za-z0-9_]+)\s*=\s*(pass|ok|true|1)\b",
        line,
        re.IGNORECASE,
    )
    if not match:
        return None
    return match.group(1).lower()


def find_evidence(lines: Iterable[str]) -> dict[str, tuple[int, str]]:
    found: dict[str, tuple[int, str]] = {}
    for line_number, line in enumerate(lines, start=1):
        marker = evidence_marker(line)
        if marker in RULE_BY_KEY and marker not in found:
            found[marker] = (line_number, line)

        for rule in RULES:
            if rule.key in found:
                continue
            if any(pattern.search(line) for pattern in rule.patterns):
                found[rule.key] = (line_number, line)
    return found


def find_forbidden_board_lines(lines: Iterable[str]) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []
    for line_number, line in enumerate(lines, start=1):
        for match in FORBIDDEN_BOARD_RE.finditer(line):
            prefix = line[max(0, match.start() - 32) : match.start()]
            if NEGATED_FORBIDDEN_PREFIX_RE.search(prefix):
                continue
            found.append((line_number, line))
            break
    return found


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate XIAO Round Display hardware bring-up evidence logs."
    )
    parser.add_argument("log", help="hardware bring-up log path, or '-' for stdin")
    parser.add_argument(
        "--profile",
        choices=["milestone0"],
        default="milestone0",
        help="required evidence set",
    )
    parser.add_argument(
        "--allow-missing",
        action="append",
        choices=sorted(RULE_BY_KEY),
        default=[],
        help="temporarily allow a missing evidence key during partial bench runs",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    lines = read_lines(args.log)
    found = find_evidence(lines)
    forbidden_board_lines = find_forbidden_board_lines(lines)
    allowed_missing = set(args.allow_missing)
    missing = [
        rule for rule in RULES if rule.key not in found and rule.key not in allowed_missing
    ]

    print("Hardware bring-up summary:")
    for rule in RULES:
        if rule.key in found:
            line_number, line = found[rule.key]
            print(f"  PASS {rule.key}: line {line_number}: {line}")
        elif rule.key in allowed_missing:
            print(f"  SKIP {rule.key}: allowed missing")
        else:
            print(f"  FAIL {rule.key}: missing {rule.label}")

    if missing or forbidden_board_lines:
        print("FAIL:")
        for rule in missing:
            print(f"  - missing {rule.label} ({rule.key})")
        for line_number, line in forbidden_board_lines:
            print(f"  - wrong board evidence at line {line_number}: {line}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
