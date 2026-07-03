#!/usr/bin/env python3
"""Regression tests for XIAO hardware bring-up evidence validation."""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import hardware_bringup_check


def missing_keys(lines: list[str], allow_missing: set[str] | None = None) -> set[str]:
    found = hardware_bringup_check.find_evidence(lines)
    allowed = allow_missing or set()
    return {
        rule.key
        for rule in hardware_bringup_check.RULES
        if rule.key not in found and rule.key not in allowed
    }


class HardwareBringupEvidenceTests(unittest.TestCase):
    def test_accepts_complete_log_with_explicit_vendor_markers(self) -> None:
        lines = [
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
        ]

        self.assertEqual(set(), missing_keys(lines))

    def test_explicit_board_identity_marker_satisfies_identity_rule(self) -> None:
        lines = ["EVIDENCE board_identity=pass"]
        found = hardware_bringup_check.find_evidence(lines)

        self.assertIn("board_identity", found)

    def test_complete_peripheral_evidence_without_board_identity_fails(self) -> None:
        lines = [
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
        ]

        self.assertEqual({"board_identity"}, missing_keys(lines))

    def test_wrong_esp32_s3_board_evidence_is_rejected_even_with_xiao_marker(self) -> None:
        lines = [
            "USB: Seeed Studio XIAO nRF52840 mounted at /dev/cu.usbmodem101",
            "Connected USB board: ESP32-S3",
        ]

        self.assertEqual(
            [(2, "Connected USB board: ESP32-S3")],
            hardware_bringup_check.find_forbidden_board_lines(lines),
        )

    def test_current_esp32_usb_identity_is_rejected_as_wrong_board(self) -> None:
        lines = [
            "USB: Seeed Studio XIAO nRF52840 mounted at /dev/cu.usbmodem101",
            "Detected device identity: Espressif USB JTAG/serial debug unit",
            "VID:PID 303A:1001",
        ]

        self.assertEqual(
            [
                (2, "Detected device identity: Espressif USB JTAG/serial debug unit"),
                (3, "VID:PID 303A:1001"),
            ],
            hardware_bringup_check.find_forbidden_board_lines(lines),
        )

    def test_negated_esp32_s3_reference_is_not_wrong_board_evidence(self) -> None:
        lines = [
            "Connected board is XIAO nRF52840, not ESP32-S3",
            "Connected board is XIAO nRF52840 instead of Espressif USB JTAG/serial debug unit",
        ]

        self.assertEqual([], hardware_bringup_check.find_forbidden_board_lines(lines))

    def test_negation_does_not_hide_later_positive_wrong_board_identity(self) -> None:
        lines = [
            "Connected board is not ESP32-S3; detected Espressif USB JTAG/serial debug unit",
        ]

        self.assertEqual(
            [(1, lines[0])],
            hardware_bringup_check.find_forbidden_board_lines(lines),
        )

    def test_repo_map_lite_lines_do_not_satisfy_vendor_sd(self) -> None:
        lines = [
            "MapLite: SD ready",
            "MapLite: sd entry name=VECTMAP dir=1 size=0",
            "MapLite: SD list path=/ entries=1 truncated=0 error=0",
        ]
        found = hardware_bringup_check.find_evidence(lines)

        self.assertIn("repo_sdls", found)
        self.assertNotIn("vendor_sd", found)

    def test_repo_display_lines_do_not_satisfy_vendor_display(self) -> None:
        lines = [
            "DisplayRound: Seeed_GFX GC9A01 init complete",
            "DisplayRound: boot screen drawn",
            "DisplayRound: map frame route lines=3 elapsed_ms=12",
        ]
        found = hardware_bringup_check.find_evidence(lines)

        self.assertIn("repo_lcd_init", found)
        self.assertIn("repo_lcd_boot", found)
        self.assertIn("repo_lcd_map", found)
        self.assertNotIn("vendor_display", found)

    def test_repo_map_frame_requires_drawn_primitives(self) -> None:
        lines = ["DisplayRound: map frame route lines=0 elapsed_ms=12"]
        found = hardware_bringup_check.find_evidence(lines)

        self.assertNotIn("repo_lcd_map", found)

    def test_fails_when_required_repo_touch_gesture_is_missing(self) -> None:
        lines = [
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
        ]

        self.assertEqual({"repo_touch_gesture"}, missing_keys(lines))

    def test_allow_missing_only_skips_named_keys(self) -> None:
        lines = ["EVIDENCE vendor_display=pass"]
        missing = missing_keys(lines, allow_missing={"repo_touch_gesture"})

        self.assertNotIn("repo_touch_gesture", missing)
        self.assertIn("board_identity", missing)
        self.assertIn("vendor_touch", missing)
        self.assertIn("repo_sdls", missing)

    def test_main_does_not_allow_missing_board_identity(self) -> None:
        lines = [
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
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            log_path = Path(temp_dir) / "bringup.log"
            log_path.write_text("\n".join(lines), encoding="utf-8")

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                exit_code = hardware_bringup_check.main(
                    [str(log_path), "--allow-missing", "board_identity"]
                )

        self.assertEqual(1, exit_code)
        self.assertIn("FAIL board_identity", output.getvalue())
        self.assertIn("missing XIAO nRF52840 board identity", output.getvalue())

    def test_main_returns_failure_for_incomplete_log(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            log_path = Path(temp_dir) / "bringup.log"
            log_path.write_text("EVIDENCE vendor_display=pass\n", encoding="utf-8")

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                exit_code = hardware_bringup_check.main([str(log_path)])

        self.assertEqual(1, exit_code)
        self.assertIn("FAIL vendor_touch", output.getvalue())

    def test_main_returns_failure_for_wrong_board_even_with_complete_evidence(self) -> None:
        lines = [
            "USB: Seeed Studio XIAO nRF52840 mounted at /dev/cu.usbmodem101",
            "Connected USB board: ESP32-S3",
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
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            log_path = Path(temp_dir) / "bringup.log"
            log_path.write_text("\n".join(lines), encoding="utf-8")

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                exit_code = hardware_bringup_check.main([str(log_path)])

        self.assertEqual(1, exit_code)
        self.assertIn("wrong board evidence at line 2", output.getvalue())


if __name__ == "__main__":
    unittest.main()
