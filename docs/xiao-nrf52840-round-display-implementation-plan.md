# XIAO nRF52840 Round Display Implementation Plan

This plan covers a lower-power bike-computer firmware target using a Seeed
Studio XIAO nRF52840 plus the Seeed Studio 1.28-inch Round Display for XIAO,
instead of the current Waveshare ESP32-S3 Touch AMOLED setup.

The target should reuse the iOS companion app, the BLE navigation contract, and
the OSM extract pipeline where practical. It should not try to directly port
the ESP32 firmware unchanged: the current firmware relies on ESP32-only APIs,
NimBLE-Arduino, Preferences/NVS, PSRAM-backed full-screen LVGL buffers, and a
larger display/memory budget.

## Hardware Baseline

Primary hardware:

- MCU: Seeed Studio XIAO nRF52840, non-Sense unless a later task explicitly
  needs the Sense IMU/microphone.
- Display board: Seeed Studio Round Display for XIAO, SKU `104030087`.
- Screen: 1.28-inch round touch display, `240 x 240`, RGB565/65K color.
- Form factor: `39 mm x 39 mm` round display board, XIAO plugged into the rear
  headers.
- Storage: display-board microSD slot, FAT/FAT32, documented up to 32 GB.
- Power: USB-C through XIAO, display-board lithium battery connector, charge IC,
  power switch, and battery voltage sense.
- RTC: display-board PCF8563-class RTC over I2C with optional coin cell.
- Wireless: BLE from nRF52840. No Wi-Fi.

Relevant XIAO nRF52840 limits:

- CPU: nRF52840 Cortex-M4F at 64 MHz.
- RAM: 256 KB.
- Internal flash: 1 MB.
- Onboard external flash: 2 MB.
- Interfaces on the normal XIAO nRF52840: 1 SPI, 1 I2C, 1 UART, GPIO/PWM/ADC.

Round Display pin usage to reserve:

| XIAO pin | Display-board use |
| --- | --- |
| `D0/A0` | Battery voltage measurement |
| `D1` | LCD chip select |
| `D2` | microSD chip select |
| `D3` | LCD data/command |
| `D4/SDA` | I2C for touch and RTC |
| `D5/SCL` | I2C for touch and RTC |
| `D6` | Display backlight, unless the board switch releases the pin |
| `D7` | Touch interrupt |
| `D8/SCK` | Shared SPI clock |
| `D9/MISO` | Shared SPI MISO |
| `D10/MOSI` | Shared SPI MOSI |

## Product Direction

Build this as a compact BLE companion display, not as a full replacement for
the ESP32 offline map renderer in the first milestone.

MVP behavior:

- Pair with the existing iOS app as `BikeComputer` or `BikeComputer-XIAO`.
- Receive authenticated navigation instructions over the existing BLE service.
- Receive GPS position, heading, ride telemetry, route geometry, and map
  settings over the existing BLE characteristics.
- Display ride essentials on the round screen:
  - current speed,
  - heading/course,
  - next maneuver icon and distance,
  - instruction text,
  - route progress or simple breadcrumb route,
  - battery state,
  - BLE state.
- Support touch gestures for page switching, zoom/detail mode, brightness, and
  pairing/reset actions.
- Use the display-board RTC and battery measurement, but sync time from iOS GPS
  packets rather than NTP.

Deferred behavior:

- Full offline vector-map rendering from `.fmb` blocks.
- Wi-Fi, OTA, web server, telnet CLI, or ESP32 radio features.
- LVGL parity with the ESP32 UI.
- Sensor-fusion/IMU behavior unless the Sense board is selected later.

## Architecture

Create a separate firmware target instead of folding nRF52840 conditionals into
the existing `esp32/` tree.

Proposed layout:

```text
xiao-nrf52840/
  platformio.ini
  src/main.cpp
  include/
  lib/
    ble_navigation/
    display_round/
    ui_round/
    diagnostics/
    settings_store/
    storage/
    power/
    protocol/
```

Keep `esp32/` intact while the new target comes up. After the nRF target can
build and connect to iOS, move only genuinely portable code into a shared
module. Good shared candidates are packet parsing, route geometry decoding,
icon IDs, map-setting IDs, and fixed-point coordinate helpers. Poor shared
candidates are display flush, task scheduling, preferences, BLE stack wrappers,
and SD driver setup.

Current repo checkpoint:

- `xiao-nrf52840/` now contains a PlatformIO firmware target that builds for
  `xiao_nrf52840_round`.
- `xiao-nrf52840/` also contains a native PlatformIO test target,
  `native_protocol`, that exercises the portable BLE protocol parser without
  requiring XIAO hardware.
- Repo-side Milestone 1 through Milestone 4 slices are implemented: pin/display
  skeleton, Bluefruit BLE server/auth/protocol parsing, MVP UI state machine,
  approximate heap/runtime diagnostics, and InternalFS brightness settings.
  Display rendering now compiles against Seeed_GFX using the Round Display
  `BOARD_SCREEN_COMBO 501`/GC9A01 setup, with boot/status text and route/map
  line primitives routed to the LCD backend while serial logs remain available
  for bench diagnostics.
  Route geometry is decoded into a fixed 128-point in-memory preview for
  breadcrumb/heading state, and diagnostics now include stored route points,
  battery voltage/percent, brightness, render timing, and the nRF52 reset
  reason captured by the board core at boot.
  Map/display settings received over BLE, including minimum polygon size, are
  restored at boot and debounced to InternalFS after updates. The XIAO target
  also honors the existing
  authenticated settings command `id=5,value=1` by scheduling a short delayed
  nRF52 software reset, matching the iOS settings screen's reboot button.
- A serial simulation console can inject navigation, GPS, route, and settings
  packets through the same parser/update path for bench-side simulated rides
  when iOS BLE or XIAO hardware is not yet available.
  `xiao-nrf52840/tools/serial_sim_ride.py` generates deterministic 60-minute
  command streams for repeatable parser/UI soak traffic over that console. The
  console also supports `DIAG`/`STATUS` for immediate diagnostics snapshots, and
  the generator emits `DIAG` at deterministic intervals by default so soak logs
  capture heap, BLE, route, power, RTC, idle, and map-lite counters.
  `xiao-nrf52840/tools/serial_log_check.py` validates captured serial evidence,
  including the strict `--profile serial-soak-60` profile for 60-minute
  firmware-side soak runs.
- Touch interrupt page switching is enabled during standalone bring-up before
  setting ID `11` arrives; after iOS sends that setting, the tap-to-switch value
  controls whether touch interrupt taps cycle pages. Repo-side gesture handling
  is now implemented behind a serial `TOUCH` simulation command: left/right
  swipes change pages, center tap toggles ride data density, long press opens
  settings, center tap in settings toggles north-up/course-up map orientation,
  up/down swipes adjust brightness on the settings page, and a repeated long
  press in settings disconnects the current BLE client and clears peripheral
  bonds to force a reconnect/pairing reset. The existing authenticated
  `id=5,value=1` settings command remains the delayed software reboot path.
  Real coordinate/duration decoding remains gated on touch-controller hardware
  bring-up.
- Repo-side Milestone 5 power support is started: battery ADC sampling,
  estimated battery percentage, low-battery state, manual target brightness,
  conservative auto-dim, and disconnected-idle backlight-off behavior are
  implemented in `lib/power/`.
  A cooperative idle manager now yields short bounded windows after each loop so
  the nRF52 FreeRTOS/tickless-idle path can enter its `waitForEvent()` sleep
  behavior between BLE/UI work; diagnostics log idle call counts and idle
  milliseconds.
  RTC support is also repo-side implemented for the display-board
  PCF8563/PCF85063-class chip at `0x51`, with BLE GPS Unix-time sync plus
  UI/diagnostic status. The iOS app now keeps active navigation GPS writes at
  live update cadence, and sends the same `2A72` GPS/Unix-time packet at a
  low-frequency 10-minute cadence when connected but no navigation session is
  active.
- Runtime, thermal, mount, vibration, and waterproofing validation are tracked
  in `hardware/xiao-round-display-power-enclosure.md`.
- Repo-side Milestone 6 map-lite probing is started: `lib/map_lite/` initializes
  the Round Display microSD SPI bus through SdFat, probes known `.fmb` lookup
  paths, scans `.fmb` feature records without allocating feature arrays, and
  logs candidate feature counts/timing plus a provisional `candidate`,
  `too-slow`, `too-complex`, `no-data`, or `invalid` decision. The probe is now
  driven from the latest BLE GPS fix: the firmware converts microdegree
  latitude/longitude into Web Mercator meters and scans only when the current
  4096 m map block changes, with throttling for simulated jumps. Runtime
  diagnostics include SD readiness, probe count, last block, open/scan timing,
  candidate point count, and the provisional decision, and the serial simulator
  has direct `SDLS` and `MAPPROBE` commands for hardware SD-card directory and
  block checks. The Route page also has a bounded preview renderer that reopens
  the last probed block, skips polygon bodies, streams candidate polylines, and
  draws at most 160 line segments through the XIAO display primitive API; the
  Seeed_GFX backend renders and logs those primitives for hardware evidence.
  Map-lite core math and decision thresholds now have native tests covering
  Mercator conversion, negative block/folder path formatting, candidate feature
  classification, screen mapping, and go/no-go decisions. The Route page also
  draws a bounded route breadcrumb overlay centered on the current GPS fix, or
  the route start before GPS arrives, through the same display primitive API.
- The XIAO target exposes BLE Device Information Service metadata, and the iOS
  app reads/surfaces the hardware model label when present while keeping scan
  and navigation writes on the existing BikeComputer service/characteristics.
- Milestone 0 hardware proof is tracked in
  `hardware/xiao-nrf52840-round-display-bringup.md`; the current connected USB
  board is the ESP32-S3, not the XIAO nRF52840.
- Upload, real boot-screen verification, iOS discovery/authentication, touch,
  calibrated battery readings, RTC, microSD, map-lite timing, runtime, thermal,
  enclosure, and ride-duration validation are still pending a connected XIAO
  nRF52840 Round Display.
- The iOS companion app now opens to a full-screen map with overlay controls.
  Route entry is handled by the inline `RouteSearchPanel` rather than the older
  full-screen route-input cover.
- The current local iOS changes compile for the `BikeComputer` simulator target.

## Toolchain Plan

Use PlatformIO for repo consistency, with a fallback to Arduino IDE only for
vendor example validation.

Initial PlatformIO direction:

```ini
[env:xiao_nrf52840_round]
platform = https://github.com/Seeed-Studio/platform-seeedboards.git
board = seeed-xiao-afruitnrf52-nrf52840
framework = arduino
monitor_speed = 115200
```

First build dependencies to evaluate:

- Seeed round display support: `Seeed_Arduino_RoundDisplay` and/or `Seeed_GFX`.
- Display drawing: prefer Arduino GFX / Seeed GFX on nRF52840. Avoid LVGL in
  phase 1 unless a measured prototype proves the RAM budget is acceptable.
- BLE stack: use the Seeed nRF52/Adafruit Bluefruit nRF52 APIs available in the
  board package, not NimBLE-Arduino.
- Storage: start with the SD library used by Seeed examples; switch to SdFat
  only if needed for performance or directory traversal.
- HMAC-SHA256: add a small portable crypto module or library because the ESP32
  firmware currently uses `mbedtls`, which should not be assumed available on
  the nRF target.

Bring-up commands should eventually mirror the ESP32 workflow:

```sh
cd xiao-nrf52840
pio run -e xiao_nrf52840_round
pio run -e xiao_nrf52840_round -t upload
pio device monitor -b 115200
```

## BLE Contract

Preserve the existing BLE service UUID and characteristic UUIDs documented in
`docs/ble-protocol.md`:

| UUID | Direction | Purpose |
| --- | --- | --- |
| `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800` | service | Bike computer service |
| `2A6E` | iOS to device | Navigation instruction text |
| `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002` | bidirectional | Local auth handshake |
| `2A6F` | iOS to device | Binary route geometry |
| `2A72` | iOS to device | GPS position, heading, Unix time, and optional ride telemetry |
| `2A73` | iOS to device | Runtime map/display settings |

Implementation notes:

- Keep the same HMAC challenge/response so the iOS app can treat ESP32 and XIAO
  devices as the same trusted accessory class.
- Discovery is service-UUID based. The advertised name can be `BikeComputer` or
  `BikeComputer-XIAO`, but the XIAO target must advertise the existing service
  UUID so the app can discover it during pairing and reconnect through the
  trusted CoreBluetooth peripheral identifier.
- If the Bluefruit stack has lower MTU/write limits than the ESP32 path, keep
  the existing fallback framing strategy and add chunking only inside the iOS
  BLE queue and nRF parser.
- Store persistent pairing identity/settings in the nRF flash or external QSPI
  flash through the board core's supported storage API. Do not assume ESP32
  `Preferences`.
- Add a device information characteristic or advertised manufacturer data only
  after the base iOS flow works; the iOS app can use it to label the device as
  `XIAO nRF52840 Round`.

Optional later characteristic:

| UUID | Direction | Purpose |
| --- | --- | --- |
| `2A74` | iOS to device | Cycling telemetry such as speed, elapsed time, distance, heart rate, cadence, power |

Do not add `2A74` until there is a concrete UI feature that needs telemetry not
already carried by the extended `2A72` GPS packet. The current iOS app can send
speed, altitude, distance traveled, elapsed time, and route remaining in `2A72`;
heart rate, cadence, and power would still need a new field or characteristic if
the device UI requires them.

## Display And UI Plan

The round display should get a purpose-built UI instead of resizing the ESP32
LVGL screens.

Rendering strategy:

- Use direct drawing through Arduino GFX / Seeed GFX first.
- Maintain a small view model in RAM and redraw only changed regions where
  practical.
- Avoid full-screen double buffering. A single `240 x 240 x 2` framebuffer is
  about 115 KB before stack, BLE, SD, route, and UI state; double buffering is
  not realistic on 256 KB RAM.
- Use small sprites only for dynamic widgets that flicker without buffering:
  maneuver icon, speed number, route-progress arc, and status strip.
- Keep assets as compact RGB565/RLE arrays or draw icons procedurally.
- Use a circular safe area. Text and icons should avoid the clipped corners of
  the square framebuffer.

Initial pages:

1. Ride page: speed, distance/elapsed, BLE/battery, next maneuver distance.
2. Navigation page: large maneuver icon, instruction text, route progress.
3. Route page: simplified route polyline/breadcrumb centered on current
   position; no offline map background in MVP.
4. Settings overlay: brightness, map orientation, reconnect/pairing reset.

Touch handling:

- Initialize I2C on `D4/D5`.
- Use `D7` touch interrupt as the wake/read hint.
- Treat touch reads as event-driven with a short debounce and no tight polling.
- Gesture map:
  - swipe left/right: switch page,
  - tap center: toggle data density,
  - long press: settings overlay,
  - swipe up/down in settings: brightness.

## Storage And Map Strategy

Phase 1 storage:

- Verify microSD init with the Round Display pinout: `CS=D2`, `SCK=D8`,
  `MISO=D9`, `MOSI=D10`.
- Store logs, screenshots/debug dumps if feasible, and simple config backups.
- Load optional small icon/font assets from flash or SD only after BLE/display
  stability is proven.

Phase 1 route view:

- Use iOS-sent route geometry from `2A6F`.
- Downsample route points to a bounded in-memory polyline, for example 128-256
  points.
- Render the route as a simplified line relative to the current GPS position.
- Preserve the current north-up/course-up map setting IDs.

Phase 2 map-lite experiment:

- Read `.fmb` blocks generated by `OSM_Extract`, but render a strict subset:
  major roads, water, parks, and route overlay.
- Stream parse features from SD and draw directly to display-space spans or
  small draw lists.
- Avoid storing full polygons, full map tiles, or full-screen map buffers.
- Add feature budgets per frame and degrade gracefully when SD reads or drawing
  exceed the frame budget.

Phase 2 acceptance should be explicit: if map-lite cannot keep UI latency under
about 150 ms per visible interaction, keep the XIAO product as a nav/metrics
companion and leave full offline maps on ESP32-S3-class hardware.

## Power Plan

Power should be a first-class reason for this port.

Implementation tasks:

- Read battery voltage from `D0/A0` using the nRF52840 ADC reference/calibration
  pattern from Seeed's Round Display examples.
- Drive backlight on `D6` with brightness levels and an auto-dim timer.
- Use the Round Display switch as the physical master power path when battery
  powered through the display board.
- Sync RTC from GPS packets that include Unix time, matching the existing ESP32
  BLE protocol behavior.
- Use nRF sleep modes between BLE/display work when the UI is idle.
- Wake on BLE events, touch interrupt, and periodic RTC/display ticks.

Power milestones:

- USB powered, screen always on.
- Battery powered, manual brightness.
- Battery powered, auto-dim.
- Battery powered, low-power idle while connected.
- Battery powered, disconnected sleep with touch/power-button recovery.

## Implementation Milestones

### Milestone 0: Vendor Examples And Pin Confirmation

- Build and upload Seeed's Round Display hardware test on the XIAO nRF52840.
- Confirm display, touch, RTC, battery ADC, and microSD independently.
- Record working upload/serial notes in `AGENTS.md` or a new hardware note.
- Decide whether the board is non-Sense or Sense for the first product path.

Exit criteria:

- A serial log shows display init, touch event, RTC read, battery read, and SD
  mount on the same firmware.

### Milestone 1: Repo Firmware Skeleton

- Add `xiao-nrf52840/platformio.ini`.
- Add a minimal `src/main.cpp` with serial logging and board init.
- Add `display_round` with `begin()`, `setBrightness()`, `drawBootScreen()`,
  and `drawStatus()`.
- Add a compile-time hardware definition file for the Round Display pins.

Exit criteria:

- `pio run -e xiao_nrf52840_round` builds from the repo.
- Upload shows a boot screen and serial heartbeat.

### Milestone 2: BLE Server Port

- Implement a Bluefruit-backed BLE server wrapper with the same service and
  characteristics as `docs/ble-protocol.md`.
- Port packet parsing and auth into hardware-independent modules.
- Add small debug counters equivalent to `BLEDebugStats`.
- Keep all map/route writes bounded by maximum packet length and route-point
  budget.

Exit criteria:

- iOS discovers and authenticates the XIAO target.
- `2A6E`, `2A6F`, `2A72`, and `2A73` writes are accepted and logged.
- Existing iOS tests remain valid, with any XIAO-specific behavior documented.

### Milestone 3: MVP Bike UI

- Draw ride, navigation, route, and settings pages.
- Implement touch page switching.
- Render maneuver icons and instruction text.
- Compute speed from GPS deltas when the iOS app does not send explicit speed.
- Render BLE, GPS freshness, battery, and RTC status.

Exit criteria:

- Starting a route in the iOS app updates the XIAO display within one BLE write
  cycle.
- The screen remains legible outdoors at the chosen brightness.
- Touch gestures do not interfere with BLE writes or display refresh.

### Milestone 4: Ride Robustness

- Bound memory use and add a boot-time free-RAM log.
- Add route packet hash/debounce similar to the ESP32 firmware.
- Handle disconnect/reconnect without reboot.
- Persist brightness and key display settings.
- Add serial diagnostics for BLE state, GPS freshness, route point count,
  battery voltage, and render timing.

Exit criteria:

- A 60-minute simulated ride can run from iOS without heap exhaustion, display
  lockup, or BLE reconnect failure.
  The serial simulation console can exercise the same parser/UI state path from
  USB serial, but it does not satisfy the iOS BLE/reconnect portion of this
  exit criterion.
  Use `tools/serial_sim_ride.py --duration 3600 --interval 1` to produce a
  repeatable serial soak profile for firmware-side parser/UI checks. The stream
  emits `DIAG` every 300 seconds by default; pass `--diag-period 0` only when
  relying on the firmware's periodic runtime diagnostics instead. Validate the
  captured log with `tools/serial_log_check.py --profile serial-soak-60`.

### Milestone 5: Power And Enclosure Bring-Up

- Tune auto-dim and sleep behavior.
- Validate battery runtime with the target display brightness.
- Add a mount/enclosure note under `hardware/`.
- Define waterproofing and vibration assumptions before outdoor use.

Exit criteria:

- Battery runtime and thermal behavior are measured, not guessed.
- The device can recover cleanly from screen-off idle and BLE reconnect.

### Milestone 6: Optional Map-Lite

- Prototype `.fmb` block lookup from the display-board microSD slot.
- Render a restricted map subset behind the route.
- Measure SD read timing, draw timing, and route update latency.
- Decide whether map-lite belongs in the XIAO target or should remain a
  separate experiment.

Exit criteria:

- A documented go/no-go decision based on measured RAM, frame time, and ride UI
  responsiveness.

## iOS App Changes

Required:

- Keep the existing BLE UUIDs and write formats unchanged.
- Keep scan/connect behavior service-UUID based. The app does not currently
  filter by advertised name, so `BikeComputer-XIAO` is acceptable as a display
  name only if the service UUID is still advertised.
- Surface a hardware label when the firmware exposes one.
- Keep fallback framed writes over `2A6E` because MTU behavior may differ on
  nRF52.
- Send target brightness over the existing `2A73` settings path using setting
  ID `12`; the XIAO firmware applies it through the power manager and persists
  it with the rest of the device settings.

Optional:

- Add a compact telemetry write only if the device UI needs HealthKit-derived
  fields that are not already represented in the extended `2A72` packet.

## Branch And PR Hygiene

- Do not include `codex` in branch names for this work, in any capitalization.
- Do not include `codex` in pull request titles for this work, in any
  capitalization.

## Test Plan

Build tests:

- `cd xiao-nrf52840 && pio run -e xiao_nrf52840_round`
- `cd xiao-nrf52840 && pio test -e native_protocol`
- Existing iOS unit tests for navigation protocol.
- iOS compile check: build the `BikeComputer` scheme for an iOS simulator after
  touching companion-app code.

Hardware tests:

- Cold boot on USB.
- Cold boot on battery through the Round Display board.
- Display init and brightness control.
- Touch tap/swipe/long-press.
- RTC read after USB reset and after full power removal with coin cell fitted.
- Battery ADC calibration at full, mid, and low pack voltage.
- microSD mount and directory listing with a 32 GB FAT32 card using `SDLS / 24`.
- BLE scan/auth/write/reconnect from iOS.
- 60-minute simulated ride.
- Outdoor readability and touch behavior with gloves/wet screen as a later
  field test, not a desk test.

Memory tests:

- Log free RAM after boot, after BLE connect, after route packet, after SD
  mount, and after 60 minutes. Use `DIAG`/`STATUS` over serial to request
  deterministic snapshots at those checkpoints during bench validation, and use
  `tools/serial_log_check.py` to fail missing, malformed, or regressed evidence.
- Log reset reason at boot and include the raw reset reason in runtime
  diagnostics so watchdog, lockup, reset-pin, and system-off recoveries are
  visible during soak rides.
- Reject route payloads that exceed the configured point budget instead of
  allocating dynamically until failure.

## Risks And Decisions

- RAM is the main constraint. Treat full LVGL, full-screen buffers, and the
  existing ESP32 map renderer as out of scope until proven otherwise.
- BLE library differences are real. The nRF target needs its own BLE wrapper
  while preserving the over-the-air protocol.
- The product page URL names ESP32, but Seeed's Round Display documentation and
  product bundle list XIAO nRF52840 compatibility. Validate on the bench before
  committing to enclosure work.
- The Round Display shares SPI between LCD and SD. Every display/SD operation
  must use clean transactions and explicit chip-select handling.
- If offline map-lite causes UI stalls, keep the XIAO firmware focused on
  navigation, metrics, route breadcrumb, and battery life.

## Reference Sources

- Seeed product page:
  `https://www.seeedstudio.com/1-28-Round-Touch-Display-for-Seeed-Studio-XIAO-ESP32.html`
- Seeed Round Display getting-started wiki:
  `https://wiki.seeedstudio.com/get_start_round_display/`
- Seeed Round Display hardware usage wiki:
  `https://wiki.seeedstudio.com/seeedstudio_round_display_usage/`
- Seeed Round Display LVGL/TFT wiki:
  `https://wiki.seeedstudio.com/using_lvgl_and_tft_on_round_display/`
- Seeed XIAO nRF52840 wiki:
  `https://wiki.seeedstudio.com/XIAO_BLE/`
- Seeed XIAO nRF52840 PlatformIO wiki:
  `https://wiki.seeedstudio.com/xiao_nrf52840_with_platform_io/`
- Seeed XIAO nRF52840 Bluetooth usage wiki:
  `https://wiki.seeedstudio.com/XIAO-BLE-Sense-Bluetooth_Usage/`
- Local BLE protocol:
  `docs/ble-protocol.md`
- Local ESP32/Waveshare implementation plan:
  `docs/waveshare-hardware-native-implementation-plan.md`
