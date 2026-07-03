#!/usr/bin/env python3
"""Regression tests for XIAO serial ride command generation."""

from __future__ import annotations

import contextlib
import io
import unittest

import serial_sim_ride


def generated_commands(*args: str) -> list[str]:
    parsed = serial_sim_ride.parse_args(list(args))
    return list(serial_sim_ride.emit_commands(parsed))


class SerialRideGeneratorTests(unittest.TestCase):
    def test_generates_settings_route_gps_and_shutdown_commands(self) -> None:
        commands = generated_commands(
            "--duration",
            "10",
            "--interval",
            "5",
            "--touch-period",
            "0",
            "--diag-period",
            "0",
        )

        self.assertEqual("SIM ON", commands[0])
        self.assertIn("SET 12 80", commands)
        self.assertIn("SET 7 3", commands)
        self.assertIn("SET 6 1", commands)
        self.assertEqual(1, sum(command.startswith("ROUTEHEX ") for command in commands))
        self.assertEqual(3, sum(command.startswith("GPS ") for command in commands))
        self.assertEqual("ROUTECLEAR", commands[-2])
        self.assertEqual("SIM OFF", commands[-1])

    def test_duplicate_route_emits_initial_geometry_twice(self) -> None:
        commands = generated_commands(
            "--duration",
            "10",
            "--interval",
            "5",
            "--duplicate-route",
            "--touch-period",
            "0",
            "--diag-period",
            "0",
        )
        route_commands = [
            command for command in commands if command.startswith("ROUTEHEX ")
        ]

        self.assertEqual(2, len(route_commands))
        self.assertEqual(route_commands[0], route_commands[1])

    def test_periodic_diag_touch_nav_and_brightness_settings(self) -> None:
        commands = generated_commands(
            "--duration",
            "120",
            "--interval",
            "30",
            "--diag-period",
            "60",
            "--touch-period",
            "60",
            "--setting-period",
            "60",
            "--nav-period",
            "30",
        )

        self.assertEqual(2, commands.count("DIAG"))
        self.assertIn("TOUCH left", commands)
        self.assertIn("TOUCH tap", commands)
        self.assertIn("SET 12 70", commands)
        self.assertIn("SET 12 80", commands)
        self.assertGreaterEqual(
            sum(command.startswith("NAV 2|") for command in commands),
            4,
        )

    def test_keep_flags_leave_route_and_sim_session_open(self) -> None:
        commands = generated_commands(
            "--duration",
            "10",
            "--interval",
            "5",
            "--touch-period",
            "0",
            "--diag-period",
            "0",
            "--keep-route",
            "--keep-sim-on",
        )

        self.assertNotIn("ROUTECLEAR", commands)
        self.assertNotIn("SIM OFF", commands)

    def test_route_point_limit_rejects_oversized_payload(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            serial_sim_ride.parse_args(["--route-points", "128"])

    def test_route_hex_rejects_large_point_delta(self) -> None:
        with self.assertRaises(ValueError):
            serial_sim_ride.route_hex([(0, 0), (40_000, 0)])


if __name__ == "__main__":
    unittest.main()
