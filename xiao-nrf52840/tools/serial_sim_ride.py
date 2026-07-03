#!/usr/bin/env python3
"""Generate serial simulator commands for XIAO firmware soak runs."""

from __future__ import annotations

import argparse
import math
import struct
import sys
from typing import Iterable


START_LAT = 1_345_000
START_LON = 103_812_000
DEFAULT_UNIX_TIME = 1_783_080_000
MAX_ROUTE_PACKET_BYTES = 512


def route_points(count: int) -> list[tuple[int, int]]:
    points: list[tuple[int, int]] = []
    for index in range(count):
        progress = index / max(count - 1, 1)
        lat = START_LAT + int(progress * 18_000)
        lon = START_LON + int(math.sin(progress * math.pi * 1.5) * 12_000)
        points.append((lat, lon))
    return points


def route_hex(points: Iterable[tuple[int, int]]) -> str:
    iterator = iter(points)
    start_lat, start_lon = next(iterator)
    payload = bytearray(struct.pack("<ii", start_lat, start_lon))
    prev_lat, prev_lon = start_lat, start_lon
    for lat, lon in iterator:
        delta_lat = lat - prev_lat
        delta_lon = lon - prev_lon
        if not -32768 <= delta_lat <= 32767 or not -32768 <= delta_lon <= 32767:
            raise ValueError("route point deltas exceed Int16 geometry limits")
        payload.extend(struct.pack("<hh", delta_lat, delta_lon))
        prev_lat, prev_lon = lat, lon
    return payload.hex()


def interpolate(points: list[tuple[int, int]], progress: float) -> tuple[int, int]:
    if not points:
        raise ValueError("route needs at least one point")
    if progress <= 0:
        return points[0]
    if progress >= 1:
        return points[-1]
    scaled = progress * (len(points) - 1)
    index = int(scaled)
    fraction = scaled - index
    lat_a, lon_a = points[index]
    lat_b, lon_b = points[index + 1]
    lat = round(lat_a + ((lat_b - lat_a) * fraction))
    lon = round(lon_a + ((lon_b - lon_a) * fraction))
    return lat, lon


def heading_between(a: tuple[int, int], b: tuple[int, int]) -> int:
    lat_a, lon_a = a
    lat_b, lon_b = b
    lat_mid = math.radians(((lat_a + lat_b) / 2) / 1_000_000)
    x = (lon_b - lon_a) * math.cos(lat_mid)
    y = lat_b - lat_a
    heading = math.degrees(math.atan2(x, y))
    if heading < 0:
        heading += 360
    return round(heading) % 360


def emit_commands(args: argparse.Namespace) -> Iterable[str]:
    points = route_points(args.route_points)
    sample_count = max(1, math.ceil(args.duration / args.interval))
    total_distance_m = max(1, int(args.duration * args.speed_cmps / 100))
    touch_cycle = ["left", "tap", "long", "tap", "up", "down", "right"]

    yield "SIM ON"
    yield "BRIGHTNESS 80"
    yield "SET 7 3"
    yield "SET 6 1"
    yield "NAV 1|400|Continue on test route"
    yield f"ROUTEHEX {route_hex(points)}"

    previous = points[0]
    for sample in range(sample_count + 1):
        elapsed = min(sample * args.interval, args.duration)
        progress = min(elapsed / max(args.duration, 1), 1.0)
        current = interpolate(points, progress)
        heading = heading_between(previous, current) if sample > 0 else 0
        distance = int(progress * total_distance_m)
        remaining = max(0, total_distance_m - distance)
        unix_time = args.start_unix + elapsed

        if sample > 0 and elapsed % args.nav_period == 0:
            maneuver_distance = max(0, remaining % 600)
            yield f"NAV 2|{maneuver_distance}|Stay on simulated route"
        if sample > 0 and elapsed % args.setting_period == 0:
            setting_cycle = sample // max(1, args.setting_period // args.interval)
            yield f"SET 7 {2 + (setting_cycle % 3)}"
            yield f"BRIGHTNESS {60 + ((setting_cycle % 3) * 10)}"
        if sample > 0 and args.touch_period > 0 and elapsed % args.touch_period == 0:
            touch_step = sample // max(1, args.touch_period // args.interval)
            touch_index = (touch_step - 1) % len(touch_cycle)
            yield f"TOUCH {touch_cycle[touch_index]}"

        lat, lon = current
        yield (
            f"GPS {lat} {lon} {heading} {unix_time} {args.speed_cmps} "
            f"{args.altitude_m} {distance} {elapsed} {remaining}"
        )
        previous = current

    if args.clear_route:
        yield "ROUTECLEAR"
    if args.sim_off:
        yield "SIM OFF"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate commands for the XIAO serial simulation console."
    )
    parser.add_argument("--duration", type=int, default=3600, help="ride seconds")
    parser.add_argument("--interval", type=int, default=1, help="GPS sample interval seconds")
    parser.add_argument("--route-points", type=int, default=96, help="route geometry points")
    parser.add_argument("--speed-cmps", type=int, default=650, help="simulated speed")
    parser.add_argument("--altitude-m", type=int, default=35, help="simulated altitude")
    parser.add_argument("--start-unix", type=int, default=DEFAULT_UNIX_TIME)
    parser.add_argument("--nav-period", type=int, default=30, help="navigation update period")
    parser.add_argument("--setting-period", type=int, default=300, help="setting update period")
    parser.add_argument(
        "--touch-period",
        type=int,
        default=120,
        help="touch gesture period in seconds; use 0 to disable",
    )
    parser.add_argument("--keep-route", action="store_false", dest="clear_route")
    parser.add_argument("--keep-sim-on", action="store_false", dest="sim_off")
    parser.set_defaults(clear_route=True, sim_off=True)
    args = parser.parse_args(argv)
    if args.duration <= 0 or args.interval <= 0:
        parser.error("--duration and --interval must be positive")
    if args.route_points < 2:
        parser.error("--route-points must be at least 2")
    if 8 + ((args.route_points - 1) * 4) > MAX_ROUTE_PACKET_BYTES:
        parser.error("--route-points creates a route payload larger than 512 bytes")
    if args.nav_period <= 0 or args.setting_period <= 0:
        parser.error("--nav-period and --setting-period must be positive")
    if args.touch_period < 0:
        parser.error("--touch-period must be non-negative")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    for command in emit_commands(args):
        print(command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
