# XIAO nRF52840 Round Display Firmware

Lower-power bike-computer firmware target for the Seeed Studio XIAO nRF52840
and Seeed Studio 1.28-inch Round Display for XIAO.

This target is intentionally separate from `esp32/` so the ESP32-S3 Waveshare
firmware can stay intact while the nRF52840 path comes up.

## Build

Use a healthy Python 3.10-3.13 PlatformIO install. The global `pio` on Chris's
Mac may point at an unhealthy Python 3.11 install; prefer an isolated venv when
in doubt.

Current verified build command:

```sh
cd xiao-nrf52840
PLATFORMIO_CORE_DIR=/tmp/open-bike-pio-core-313 /tmp/open-bike-pio-313/bin/pio run -e xiao_nrf52840_round
```

## Native Tests

The portable BLE protocol parser, map-lite core helpers, battery
calibration/brightness math, settings persistence formatting/parsing, route
hash/debounce decisions, RTC conversion/register decoding, serial simulator
command numeric validation, idle-delay and auto-dim/screen-off policy, and UI
gesture/maneuver/route rotation helpers can be tested without connected
hardware:

```sh
cd xiao-nrf52840
PLATFORMIO_CORE_DIR=/tmp/open-bike-pio-core-313 /tmp/open-bike-pio-313/bin/pio test -e native_protocol
```

The Python hardware and serial evidence checkers have standard-library unit
tests:

```sh
cd xiao-nrf52840
python3 -m unittest discover -s tools -p 'test_*.py'
```

## Hardware Bring-Up Evidence

Milestone 0 still requires a real XIAO nRF52840 Round Display run. Capture the
vendor `HardwareTest` output and the follow-up repo firmware checks, then
validate the combined log:

```sh
python3 tools/hardware_bringup_check.py /tmp/xiao-hardware-bringup.log
```

The log must include board identity evidence for the Seeed XIAO nRF52840, plus
the vendor display, touch, RTC, battery, and microSD checks. The follow-up repo
firmware evidence must include SD listing output, LCD init, boot/status drawing,
nonzero map/route line primitives, touch coordinates, and a classified gesture.
If the USB or vendor output uses unexpected wording, add
`EVIDENCE board_identity=pass` only after verifying the connected board. The
checker rejects logs that still show ESP32-S3 board evidence.

The bring-up record lives at
`../hardware/xiao-nrf52840-round-display-bringup.md`.

After the individual hardware logs are captured, place them in one directory
with the names expected by the bundle checker and validate the full evidence set:

```sh
python3 tools/evidence_bundle_check.py /tmp/xiao-evidence
```

Use `--skip-map-lite` only when the optional map-lite experiment was not run.
The required log names are `hardware-bringup.log`, `ios-ble-session.log`,
`ios-ble-reconnect.log`, `ios-ble-ride-60.log`, `serial-soak-60.log`,
`route-duplicate.log`, `power-rtc-calibration.log`, `power-runtime.log`, and
`power-screen-off-recovery.log`. Add `map-lite.log` unless using
`--skip-map-lite`.

## Serial Simulation

The firmware exposes a USB serial simulation console for bench-side ride state
injection. It reuses the BLE parser/update path and marks diagnostics as a
simulation-authenticated session until `SIM OFF`.

Examples:

```text
HELP
SIM ON
NAV 3|120|Turn left on River Valley Road
GPS 1345000 103812000 275 1783080000 765 42 12345 987 4321
SET 7 4
SET 12 80
TOUCH long
TOUCH up
BLE DISCONNECT
BLE RESET
DIAG
SDLS / 24
MAPLITE ON
MAPPROBE 11556000 149000
ROUTECLEAR
SIM OFF
```

Binary packet paths are available for exact BLE payload replay:

```text
GPSHEX <little-endian hex payload>
ROUTEHEX <little-endian hex payload>
SETHEX <little-endian hex payload>
FRAMEHEX <MAPR/GPSP/MSET-prefixed hex payload>
```

This is useful for parser/UI soak work, but it does not replace the required
iOS BLE auth/reconnect or Round Display hardware validation.

For real iOS BLE session evidence, pair/authenticate from the iOS app, start a
route, let the app send navigation, route geometry, GPS, and settings writes,
request `DIAG`, then validate the captured device log:

```sh
python3 tools/serial_log_check.py /tmp/xiao-ios-ble.log --profile ios-ble-session
```

The `ios-ble-session` profile forbids serial simulation evidence and requires
one diagnostic snapshot to show an authenticated session plus the navigation,
route, GPS, settings, and route-distance counters.

For real iOS reconnect evidence, start a route from the iOS app, capture a
passing `ios-ble-session` snapshot, disconnect or reset BLE, reconnect and
reauthenticate from iOS, send navigation/route/GPS/settings writes again, then
request `DIAG` and validate the log:

```sh
python3 tools/serial_log_check.py /tmp/xiao-ios-reconnect.log --profile ios-ble-reconnect
```

The `ios-ble-reconnect` profile forbids serial simulation evidence, requires at
least two connects, one disconnect, two authenticated sessions, and requires the
current post-reconnect session counters to include navigation, route-path, GPS,
and settings writes in one authenticated diagnostic snapshot. A post-reconnect
route-path event can be either a newly accepted route packet or a duplicate
route resend that the firmware correctly debounced. The post-reconnect snapshot
must also follow an earlier captured session snapshot and show increased
`connect_count`, `disconnect_count`, and `auth_successes` counters.

For real iOS 60-minute ride evidence, keep the iOS route session active for at
least one hour, capture periodic `DIAG` snapshots, and validate the log:

```sh
python3 tools/serial_log_check.py /tmp/xiao-ios-ride-60.log --profile ios-ble-ride-60
```

The `ios-ble-ride-60` profile forbids serial simulation evidence and requires a
60-minute uptime, at least 12 diagnostic snapshots, authenticated iOS BLE
traffic, navigation/route/settings writes, at least 3600 GPS packets, nonzero
route distance, fresh GPS at the passing one-hour snapshot, nonzero heap, and
`render_max_ms` no higher than 150 ms in the passing diagnostic snapshot.

For repeatable soak input, generate a 60-minute command stream:

```sh
cd xiao-nrf52840
python3 tools/serial_sim_ride.py --duration 3600 --interval 1 > /tmp/xiao-serial-sim-ride.txt
```

After uploading to a real XIAO, feed the commands to the monitor or serial port
at 115200 baud. The stream starts with `SIM ON`, sends route/GPS/nav/settings
traffic, changes target brightness through `SET 12`, clears the route, and ends
with `SIM OFF`.
It also emits periodic `TOUCH` gestures by default so page switching, density
toggle, settings entry, map-orientation toggle, and brightness adjustment paths
are included in soak runs; pass `--touch-period 0` to disable those gestures.
It emits `DIAG` every 300 seconds by default so heap, BLE, route, power, RTC,
idle, and map-lite counters are captured at deterministic points in the serial
log; use `--diag-period 0` to rely only on periodic runtime diagnostics.
Captured logs can be checked with:

```sh
python3 tools/serial_log_check.py /tmp/xiao-serial.log
python3 tools/serial_log_check.py /tmp/xiao-serial.log --profile serial-soak-60
```

The `serial-soak-60` profile expects at least 12 diagnostic snapshots, 60
minutes of heartbeat uptime, GPS/navigation/route/settings traffic, retained
route preview points, nonzero route total distance, nonzero heap, and no
rejected/failed/reboot lines.
For power and brightness evidence, add field/range gates to the same captured
log check:

```sh
python3 tools/serial_log_check.py /tmp/xiao-serial.log \
  --profile serial-soak-60 \
  --require-diagnostic-field battery_scale_permille \
  --min-brightness 60 \
  --max-brightness 100
```

For battery calibration and RTC evidence, capture a hardware log after running
`BATCAL measured_mV` and after a GPS timestamp has synced or the RTC has restored
time, then run:

```sh
python3 tools/serial_log_check.py /tmp/xiao-power-rtc.log --profile power-rtc-calibration
```

The `power-rtc-calibration` profile requires battery voltage, percentage,
explicit `BATCAL` calibration log evidence before the passing diagnostic
snapshot, persisted `battery_scale_permille`, RTC presence, RTC-valid evidence,
and an `rtc_source` of `ble` or `rtc` in one complete diagnostic snapshot. It
also rejects captured logs that contain failed `BATCAL` attempts.

For measured battery runtime and thermal evidence, append a bench-measured
evidence line to the same captured log:

```text
EVIDENCE runtime_minutes=95 thermal_max_c=42 start_battery_mv=4120 end_battery_mv=3480 brightness_pct=80
```

Then validate the log:

```sh
python3 tools/serial_log_check.py /tmp/xiao-power-runtime.log --profile power-runtime
```

The `power-runtime` profile requires successful `BATCAL` evidence before the
passing battery diagnostic snapshot, plausible battery voltage/scale fields,
measured runtime of at least 30 minutes, at least 50 mV battery-voltage drop,
`brightness_pct` in 5..100, `thermal_max_c <= 50`, and
`start_battery_mv`/`end_battery_mv` values that match the diagnostic
`battery_mv` maximum/minimum within 150 mV by default.

For duplicate route debounce evidence, generate the command stream with
`--duplicate-route`, request `DIAG`, and require at least one ignored duplicate
without increasing the accepted route packet count:

```sh
python3 tools/serial_sim_ride.py --duration 120 --duplicate-route > /tmp/xiao-route-dup.commands
python3 tools/serial_log_check.py /tmp/xiao-route-dup.log \
  --min-route-packets 1 \
  --min-route-duplicates 1
```

For reconnect evidence, include `BLE DISCONNECT` or `BLE RESET` in the captured
serial session, request `DIAG`, then require the connection counters:

```sh
python3 tools/serial_log_check.py /tmp/xiao-reconnect.log \
  --min-connects 1 \
  --min-disconnects 1 \
  --min-ble-resets 1
```

This serial reconnect check is only a firmware-side counter check. It does not
replace the real iOS reconnect evidence checked by `--profile ios-ble-reconnect`.

For screen-off recovery evidence, capture a diagnostic snapshot while
`screen_off=1` after at least one idle delay, wake the device by touch, reconnect
from iOS, capture another `DIAG`, then validate the ordered sequence:

```sh
python3 tools/serial_log_check.py /tmp/xiao-screen-off.log --profile power-screen-off-recovery
```

The `power-screen-off-recovery` profile forbids serial simulation evidence and
requires a screen-off idle snapshot, a later touch gesture, and a later
authenticated BLE reconnect snapshot with brightness restored. The reconnect
snapshot must increment `connect_count` and `auth_successes` beyond the
screen-off snapshot so stale counters from before idle cannot satisfy the gate.

For map-lite SD checks on hardware, `SDLS / 24` prints a bounded microSD root
directory listing, `MAPPROBE mapMetersX mapMetersY` probes a specific Web
Mercator map block directly, and `GPS lat lon ...` exercises the GPS-driven
block-change path through the main loop after explicit `MAPLITE ON` opt-in.
Capture a `DIAG` snapshot after the probe/render pass and validate the evidence
with the map-lite gates, including SD readiness, a GPS-driven found-block probe,
recorded `map_scan_ms`/`map_render_ms` timings, and a valid preview render with
at least one drawn map segment in the same candidate diagnostic snapshot:

```sh
python3 tools/serial_log_check.py /tmp/xiao-map-lite.log --profile map-lite-candidate
```

Record the final measured decision in
`../hardware/xiao-map-lite-go-no-go.md`. For a no-go result, use explicit
`--require-map-probe --require-map-sd --require-map-found
--require-map-from-gps --require-map-enabled --require-map-decision <reason>`
flags with the measured
decision label instead of the candidate profile. The full evidence bundle also
requires recorded `map_open_ms` and `map_scan_ms`, plus `map_render_ms` when a
render was attempted.

For battery calibration on hardware, measure the battery with a multimeter and
run `BATCAL measured_mV`, for example `BATCAL 4100`. The next settings save
persists the computed scale. Validate the captured result with
`tools/serial_log_check.py --profile power-rtc-calibration`.

## Upload

Do not upload while `/dev/cu.usbmodem2101` is the ESP32-S3 `VID:PID
303A:1001`. Plug in the XIAO nRF52840 and verify it appears as a Seeed/XIAO
USB device first.

```sh
cd xiao-nrf52840
pio run -e xiao_nrf52840_round -t upload --upload-port /dev/cu.usbmodemXXXX
```

If upload fails, double-tap reset on the XIAO to enter the bootloader and retry
against the bootloader serial port.

## Milestone 1 Scope

The current skeleton initializes safe GPIO state for the shared LCD/SD SPI chip
selects, backlight, and touch interrupt, then emits a serial heartbeat.
`DisplayRound` now compiles against Seeed_GFX using the Round Display
`BOARD_SCREEN_COMBO 501`/GC9A01 setup and draws the boot screen, status text,
and map/route line primitives. Real LCD output still requires Seeed's
`HardwareTest` example and repo firmware to be uploaded to the actual board.

## Milestone 2 Scope

The XIAO target now advertises the same BikeComputer BLE service contract used
by the iOS app:

- `2A6E` navigation instructions plus fallback `MAPR`, `GPSP`, and `MSET`
  frames.
- `2A6F` route geometry summary intake.
- `2A72` GPS position intake.
- `2A73` map setting intake.
- `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002` local HMAC auth handshake.

It also exposes the standard BLE Device Information Service with model,
manufacturer, hardware revision, and software revision strings so the iOS app
can label XIAO hardware when connected.

Milestone 2 proves the repo-side BLE protocol port compiles; authenticated iOS
discovery and real packet flow still require a connected XIAO nRF52840.

## Milestone 3 Scope

The repo-side MVP UI now has ride, navigation, route, and settings pages backed
by the BLE state snapshot. Route geometry is decoded into a fixed 128-point
preview for route-page point counts, route-nearby heading, and a bounded
breadcrumb overlay centered on the current GPS fix or route start. Battery
status is shown on the ride page. The navigation page renders the shared iOS
icon IDs (`1` straight, `2` left, `3` right, `4` U-turn) as direct-drawn
maneuver arrows with distance, instruction text, and a route-progress arc when
the current GPS packet includes route remaining distance. Rendering goes through
`DisplayRound` into the Seeed_GFX display backend while keeping serial status
logs for bench-side diagnostics. Touch page switching is wired to the Round
Display touch interrupt pin and Seeed_GFX CHSCX6X coordinate reads. Real touch
decoding classifies tap/long/swipe gestures by coordinate delta and press
duration, with the older interrupt-only tap switch kept as a fallback if
coordinate reads are unavailable.
The same behavior is implemented behind serial simulation as
`TOUCH tap|long|left|right|up|down`: left/right swipes change pages, center tap
toggles ride data density, long press opens settings, center tap while settings
is open toggles north-up/course-up map orientation, up/down swipes adjust
brightness while settings is open, and a second long press while settings is
open disconnects the current BLE client and clears peripheral bonds to force a
reconnect/pairing reset. The existing authenticated `SET 5 1` command remains
the delayed software reboot path. Touch coordinate behavior is compile-verified
but still needs actual controller validation.

## Milestone 4 Scope

Ride-robustness work has started with serial diagnostics for approximate free
heap, BLE connection/auth state, connect/disconnect counters, GPS freshness,
route point count, route byte count, stored route point count, route total
meters, battery voltage/percent, brightness, render timing, reset reason,
authenticated device-command count, and packet counters.
The board core captures and clears `RESETREAS` before application setup;
diagnostics logs that saved value at boot with decoded labels and repeats the
raw value in runtime snapshots. The XIAO target accepts the existing iOS reboot
command (`SET 5 1` / settings characteristic id `5`, value `1`) and performs a
short delayed `NVIC_SystemReset()` from the main BLE processing loop. Serial
commands `BLE DISCONNECT` and `BLE RESET` exercise reconnect recovery; `BLE
RESET` also clears Bluefruit peripheral bonds. Runtime diagnostics include BLE
reset counts, connection counters, and timestamps. `DIAG`/`STATUS` requests an
immediate diagnostics snapshot, and the serial soak generator emits those
snapshots periodically by default. `tools/serial_log_check.py` validates
captured serial evidence for boot heap, reset reason, diagnostic snapshot
count, packet counters, route preview points, route total meters, duplicate
route debounce, reconnect counters, uptime, malformed serial-simulator command
errors, and forbidden error lines. Native tests cover the route hash and
duplicate predicate used by the BLE server. The board core uses FreeRTOS
`heap_3`, so the heap number is an approximate linker-heap
gap rather than a full allocator fragmentation report. Brightness and
BLE-provided map/display settings are loaded from InternalFS through the
`settings_store` module; known map setting updates, including minimum polygon
size, are debounced before writing back to flash.

## Milestone 5 Scope

Power bring-up now has a repo-side `power` module for battery ADC sampling,
estimated battery percentage, low-battery state, manual target brightness, and
conservative backlight auto-dim/screen-off behavior. The iOS app sends target
brightness over the existing settings characteristic as `id=12`, and the serial
soak generator uses `SET 12` to exercise that same parser path. The serial
simulator also supports `BRIGHTNESS 5..100` for direct manual bench checks. Both
paths count as user activity and are debounced to InternalFS with the rest of
the device settings. Battery voltage starts from an assumed 2:1 divider. On
hardware, measure the battery with a multimeter and run `BATCAL measured_mV`;
the firmware computes and persists `battery_scale_permille`, then includes that
scale in power and diagnostic serial logs.

The `idle_sleep` module yields short bounded delays after each loop, skipping
the delay during fresh BLE activity or due settings writes. On the Adafruit
nRF52 core this lets FreeRTOS tickless idle use the core `waitForEvent()` path
between BLE/UI work. Runtime diagnostics include `auto_dim`, `screen_off`, idle
call counts, elapsed idle milliseconds, and whether the last idle delay happened
while screen-off and connected states were active, so screen-off and recovery
behavior can be checked during hardware rides. The idle-delay policy is also
covered by native tests for fresh BLE activity, millis wraparound, settings-save
suppression, connected, dimmed, and screen-off states. Auto-dim and disconnected
screen-off brightness decisions are native-tested too, including disconnect
activity resetting the screen-off timer.

The display-board RTC is initialized on I2C address `0x51` using `D4/D5`.
GPS packets that include Unix time sync the RTC at most every 10 minutes, using
the same timestamp source as the ESP32 target. The settings page and serial
diagnostics expose RTC presence, validity, and source; coin-cell retention still
requires hardware validation.

Runtime and enclosure validation are tracked in
`../hardware/xiao-round-display-power-enclosure.md`. Map-lite go/no-go evidence
is tracked in `../hardware/xiao-map-lite-go-no-go.md`.

## Milestone 6 Scope

Map-lite work has started as an SD-card and `.fmb` stream probe, not as a full
renderer. The experiment is off by default until a real hardware session sends
`MAPLITE ON`. The `map_lite` module initializes the Round Display microSD SPI bus,
formats the existing `/VECTMAP/<folder>/<blockX>_<blockY>.fmb` paths, scans FMB
feature records without allocating feature arrays, and logs open time, scan
time, candidate feature counts, candidate point counts, and a provisional
go/no-go decision label. The serial simulator exposes `MAPLITE ON|OFF`,
`SDLS [path] [maxEntries]`
for bounded hardware directory listing evidence. The main loop now converts the
latest BLE GPS fix to Web Mercator meters and probes only when the current 4096
m map block changes, with a short throttle to keep simulated jumps from
spamming SD reads.
`tools/serial_log_check.py` can require SD readiness, GPS-driven probe evidence,
found-block evidence, allowed decision labels, scan/render timing ceilings,
render count, drawn segment count, and zero render-budget overruns so hardware
runs produce a concrete go/no-go record.

The Route page now has a bounded map-lite preview renderer that reopens the last
probed block, streams candidate polygon outlines plus candidate polyline points,
skips non-candidate feature bodies, and draws at most 160 line segments through
the `DisplayRound` primitive API. The display
backend now renders those primitives through Seeed_GFX and still counts/logs
them for diagnostics. The route breadcrumb overlay honors the existing
north-up/course-up map rotation setting; the streamed `.fmb` background remains
a measured map-lite experiment. Runtime diagnostics expose SD readiness, probe
count, last block, open/scan timing, candidate point count, preview render
timing, render-valid status, drawn/skipped segments, and the current
`candidate`/`too-slow`/`too-complex`/`no-data`/`invalid` decision so hardware
runs can capture the evidence needed for the go/no-go decision.
