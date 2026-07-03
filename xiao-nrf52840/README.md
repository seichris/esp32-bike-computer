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

The portable BLE protocol parser and map-lite core helpers can be tested
without connected hardware:

```sh
cd xiao-nrf52840
PLATFORMIO_CORE_DIR=/tmp/open-bike-pio-core-313 /tmp/open-bike-pio-313/bin/pio test -e native_protocol
```

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
BRIGHTNESS 80
TOUCH long
TOUCH up
BLE DISCONNECT
BLE RESET
DIAG
SDLS / 24
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

For repeatable soak input, generate a 60-minute command stream:

```sh
cd xiao-nrf52840
python3 tools/serial_sim_ride.py --duration 3600 --interval 1 > /tmp/xiao-serial-sim-ride.txt
```

After uploading to a real XIAO, feed the commands to the monitor or serial port
at 115200 baud. The stream starts with `SIM ON`, sends route/GPS/nav/settings
traffic, changes target brightness, clears the route, and ends with `SIM OFF`.
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
route preview points, nonzero heap, and no rejected/failed/reboot lines.
For map-lite SD checks on hardware, `SDLS / 24` prints a bounded microSD root
directory listing, `MAPPROBE mapMetersX mapMetersY` probes a specific Web
Mercator map block directly, and `GPS lat lon ...` exercises the GPS-driven
block-change path through the main loop.

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
selects, backlight, and touch interrupt, then emits a serial heartbeat. Display
drawing is a placeholder until Seeed's `HardwareTest` example has passed on the
actual board.

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

The route/map/display renderers are still placeholders in this target. Milestone
2 proves the repo-side BLE protocol port compiles; authenticated iOS discovery
and real packet flow still require a connected XIAO nRF52840.

## Milestone 3 Scope

The repo-side MVP UI now has ride, navigation, route, and settings pages backed
by the BLE state snapshot. Route geometry is decoded into a fixed 128-point
preview for route-page point counts, route-nearby heading, and a bounded
breadcrumb overlay centered on the current GPS fix or route start. Battery
status is shown on the ride page. Rendering still goes through `DisplayRound`
serial placeholders until the vendor LCD driver is validated on hardware. Touch
page switching is wired to the Round Display touch interrupt pin as a wake/event
placeholder. Tap switching is enabled before setting ID `11` arrives so
standalone bring-up can cycle pages; after iOS syncs that setting, its value
controls whether touch interrupt taps cycle pages. Planned gesture behavior is
implemented behind serial simulation as `TOUCH tap|long|left|right|up|down`:
left/right swipes change pages, center tap toggles ride data density, long press
opens settings, center tap while settings is open toggles north-up/course-up
map orientation, up/down swipes adjust brightness while settings is open, and a
second long press while settings is open disconnects the current BLE client and
clears peripheral bonds to force a reconnect/pairing reset. The existing
authenticated `SET 5 1` command remains the delayed software reboot path. Real
coordinate/duration decoding waits for the actual touch-controller bring-up.

## Milestone 4 Scope

Ride-robustness work has started with serial diagnostics for approximate free
heap, BLE connection/auth state, GPS freshness, route point count, route byte
count, stored route point count, battery voltage/percent, brightness, render
timing, reset reason, authenticated device-command count, and packet counters.
The board core captures and clears `RESETREAS` before application setup;
diagnostics logs that saved value at boot with decoded labels and repeats the
raw value in runtime snapshots. The XIAO target accepts the existing iOS reboot
command (`SET 5 1` / settings characteristic id `5`, value `1`) and performs a
short delayed `NVIC_SystemReset()` from the main BLE processing loop. Serial
commands `BLE DISCONNECT` and `BLE RESET` exercise reconnect recovery; `BLE
RESET` also clears Bluefruit peripheral bonds. Runtime diagnostics include BLE
reset counts and timestamps. `DIAG`/`STATUS` requests an immediate diagnostics
snapshot, and the serial soak generator emits those snapshots periodically by
default. `tools/serial_log_check.py` validates captured serial evidence for
boot heap, reset reason, diagnostic snapshot count, packet counters, route
preview points, uptime, and forbidden error lines. The board core uses FreeRTOS
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
simulator supports `BRIGHTNESS 5..100`; both paths count as user activity and
are debounced to InternalFS with the rest of the device settings. Battery
voltage is based on an assumed 2:1 divider and must be calibrated against a
multimeter before it is trusted.

The `idle_sleep` module yields short bounded delays after each loop, skipping
the delay during fresh BLE activity or due settings writes. On the Adafruit
nRF52 core this lets FreeRTOS tickless idle use the core `waitForEvent()` path
between BLE/UI work. Runtime diagnostics include idle call counts and elapsed
idle milliseconds so the behavior can be checked during hardware rides.

The display-board RTC is initialized on I2C address `0x51` using `D4/D5`.
GPS packets that include Unix time sync the RTC at most every 10 minutes, using
the same timestamp source as the ESP32 target. The settings page and serial
diagnostics expose RTC presence, validity, and source; coin-cell retention still
requires hardware validation.

Runtime and enclosure validation are tracked in
`../hardware/xiao-round-display-power-enclosure.md`.

## Milestone 6 Scope

Map-lite work has started as an SD-card and `.fmb` stream probe, not as a full
renderer. The `map_lite` module initializes the Round Display microSD SPI bus,
formats the existing `/VECTMAP/<folder>/<blockX>_<blockY>.fmb` paths, scans FMB
feature records without allocating feature arrays, and logs open time, scan
time, candidate feature counts, candidate point counts, and a provisional
go/no-go decision label. The serial simulator exposes `SDLS [path] [maxEntries]`
for bounded hardware directory listing evidence. The main loop now converts the
latest BLE GPS fix to Web Mercator meters and probes only when the current 4096
m map block changes, with a short throttle to keep simulated jumps from
spamming SD reads.

The Route page now has a bounded map-lite preview renderer that reopens the last
probed block, skips polygon bodies, streams candidate polyline points, and draws
at most 160 line segments through the `DisplayRound` primitive API. The current
display backend still counts/logs primitives until the Seeed LCD driver is
validated on hardware. Runtime diagnostics expose SD readiness, probe count,
last block, open/scan timing, candidate point count, preview render timing,
drawn/skipped segments, and the current `candidate`/`too-slow`/`too-complex`/
`no-data`/`invalid` decision so hardware runs can capture the evidence needed
for the go/no-go decision.
