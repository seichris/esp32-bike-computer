# Waveshare GPS and IMU Power Cleanup Implementation Plan

## Outcome

Reduce normal-navigation power use on both Waveshare AMOLED targets by removing
two unused hardware paths:

1. Do not initialize the UART GPS receiver or create its FreeRTOS polling task.
   The iPhone remains the only live GPS source on Waveshare builds.
2. Keep both QMI8658 sensor engines disabled in production and stop all periodic
   accelerometer and gyroscope reads.

The shared `Gps` data model remains in place because BLE, maps, navigation, and
ride telemetry consume it. Hardware-GPS support remains available to the older
boards that actually use a receiver.

## Scope and invariants

- Production targets: `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206`.
- Preserve BLE GPS parsing and the existing map/navigation data flow.
- Preserve UART/NMEA GPS behavior on non-Waveshare targets.
- Preserve an explicit opt-in IMU diagnostic build path for hardware bring-up.
- Do not power down the shared Waveshare peripheral rail; the display, touch,
  RTC, and other devices depend on it.
- Do not change the BLE protocol or iOS app.

## Current behavior

### Hardware GPS

`setup()` currently creates `gpsMutex`, calls `gps.init()`, and starts
`initGpsTask()` for every normal firmware build. `gps.init()` opens `Serial2`,
and `gpsTask()` wakes every RTOS tick to poll the UART and parse NMEA data.

Waveshare navigation does not need that path. The iPhone writes position,
heading, speed, altitude, distance, elapsed time, and route-remaining data into
`gps.gpsData` through `ble_navigation.cpp`. Maps and UI read the same structure,
so removing the UART producer must not remove the model or its consumers.

### IMU

Waveshare setup currently configures the QMI8658 accelerometer and gyroscope,
the main loop samples them every 500 ms, and the system heartbeat prints their
derived orientation and movement state. No navigation, screen rotation,
wake/sleep, or ride feature consumes that state.

Skipping `imu::begin()` alone is insufficient: after a warm ESP restart, the
QMI8658 may remain powered on the shared rail with sensor engines left enabled
by the previous firmware. Production boot should therefore explicitly write
the sensor-enable register to its disabled state once.

## Implementation

### 1. Make hardware GPS an explicit board capability

Add `HAS_HARDWARE_GPS=1` to the non-Waveshare common PlatformIO flags. The
Waveshare environments use their own common section and intentionally omit the
flag. This describes the capability directly and avoids scattering negative
checks for both Waveshare model macros.

Guard the UART-only lifecycle with `HAS_HARDWARE_GPS`:

- declaration, definition, and creation of `gpsMutex`
- `gpsTask()` and `initGpsTask()` declarations and definitions
- `gps.init()` and `initGpsTask()` calls in `setup()`
- GPS baud/rate settings callbacks that can stop, start, or write to `Serial2`
- hardware-GPS-only checkpoint logging

Keep these pieces unguarded:

- the global `Gps gps` instance and `gps.gpsData`
- BLE updates to `gps.gpsData`
- the initial fallback/default latitude and longitude
- maps, navigation, widgets, and ride-telemetry consumers
- NMEA implementation needed by hardware-GPS builds

Expected Waveshare boot behavior: no GPS UART start or auto-baud delay, no
8 KiB GPS task allocation, no GPS mutex, and no once-per-tick polling loop.

Files:

- `esp32/platformio.ini`
- `esp32/src/main.cpp`
- `esp32/lib/gps/gps.cpp`
- `esp32/lib/tasks/tasks.hpp`
- `esp32/lib/tasks/tasks.cpp`
- `esp32/lib/settings/settings.hpp`
- `esp32/lib/settings/settings.cpp`

### 2. Add an explicit production IMU shutdown path

Add `waveshare_board::imu::disable()` in `qmi8658.hpp/.cpp`. It should:

1. Probe the primary `0x6B` and fallback `0x6A` addresses.
2. Confirm `WHO_AM_I` without enabling or sampling either sensor.
3. Write `CTRL7 = 0x00` to disable both accelerometer and gyroscope engines.
4. Read `CTRL7` back and report a single concise success or failure message.
5. Return harmlessly if no QMI8658 is present so boot can continue.

Do not call the existing diagnostic configuration path from `disable()` because
that path resets, configures, and re-enables both engines.

Normal Waveshare setup calls `imu::disable()` once after the shared I2C bus and
power rails are ready. It does not call `imu::begin()` or `imu::process()`, and
the five-second system heartbeat does not read or print IMU state.

Use `WAVESHARE_IMU_DIAGNOSTICS` as an opt-in build flag. When defined, the
existing `begin()`, `process()`, sample/status accessors, and IMU heartbeat stay
available for board bring-up. The standard 1.75-inch and 2.06-inch environments
must omit this flag. Replace the narrower `WAVESHARE_IMU_DEBUG_LOG` comment and
behavior so one clearly named flag controls the complete diagnostic path.

Files:

- `esp32/lib/waveshare_board/qmi8658.hpp`
- `esp32/lib/waveshare_board/qmi8658.cpp`
- `esp32/src/main.cpp`
- `esp32/platformio.ini`

### 3. Keep logs aligned with production behavior

Update startup checkpoints and the rate-limited system heartbeat so they do not
claim that GPS or IMU diagnostics are running in production. Emit at most one
IMU shutdown result during boot. Keep the existing BLE `gpsFromApp` and position
fields in the system heartbeat because they verify the active iPhone GPS path.

## Implementation sequence

1. Introduce `HAS_HARDWARE_GPS` and guard the UART task, mutex, initialization,
   and UART settings operations.
2. Build one legacy hardware-GPS target to catch missing declarations before
   changing the IMU path.
3. Implement and read back `imu::disable()`.
4. Gate IMU setup, loop processing, and heartbeat output behind
   `WAVESHARE_IMU_DIAGNOSTICS`.
5. Build both production Waveshare targets and an opt-in diagnostic variant.
6. Verify phone-supplied navigation and measure current on physical hardware.

## Verification

### Static checks

- Search the production call graph to confirm Waveshare builds cannot reach
  `Gps::init()`, `gpsTask()`, or GPS baud/rate UART operations.
- Confirm normal Waveshare builds have no call to `imu::begin()`,
  `imu::process()`, `readSample()`, or IMU heartbeat accessors.
- Confirm `imu::disable()` writes and verifies `CTRL7 = 0x00` only after I2C is
  initialized.
- Confirm BLE GPS writes and every `gps.gpsData` map/UI consumer remain intact.

### Build matrix

```sh
cd esp32
pio run -e WAVESHARE_AMOLED_175
pio run -e WAVESHARE_AMOLED_206
pio run -e MAKERF_ESP32S3
pio run -e WAVESHARE_AMOLED_175_IMU_DIAGNOSTICS
```

The dedicated diagnostic environment proves the opt-in bring-up path still
compiles. `WAVESHARE_AMOLED_206_IMU_DIAGNOSTICS` provides the equivalent path
for the 2.06-inch target.

### Runtime checks on each Waveshare model

- Boot completes with display, LVGL, SD/FFat, BLE, and touch operational.
- Serial output contains one verified IMU-disabled result and no periodic IMU
  samples.
- Serial output contains no GPS task startup or UART auto-baud activity.
- The iPhone connects and authenticates over BLE.
- Starting navigation moves from waiting to map/navigation view after the first
  phone position update.
- Position, heading, speed, altitude, distance, elapsed time, and remaining
  route data continue updating.
- Disconnect timeout, deep sleep, and BOOT-button wake still work.

### Power measurement

Measure before and after firmware on the same board with the same battery/USB
setup, brightness, screen, BLE connection state, and navigation route. Record:

- idle current while waiting for the phone
- connected navigation current after values stabilize
- at least a five-minute average for each state

The measurement validates the battery impact; functional tests alone only prove
that the unused work stopped.

## Acceptance criteria

- Production Waveshare firmware never starts `Serial2` for GPS and never creates
  the GPS mutex or task.
- BLE from the iPhone remains the sole live position source on Waveshare.
- Production boot explicitly verifies that both QMI8658 sensor engines are
  disabled, with no subsequent IMU polling.
- The standard Waveshare 1.75-inch and 2.06-inch builds pass.
- A representative non-Waveshare hardware-GPS build passes and retains its UART
  GPS behavior.
- An opt-in IMU diagnostic build still compiles and can sample the sensor.
- Physical navigation, sleep/wake, and peripheral smoke tests pass on both
  Waveshare models.
- Before/after current measurements are recorded in the implementation PR.

## Non-goals

- Removing the shared `Gps` class or NMEA support from hardware-GPS boards.
- Changing iPhone location cadence, BLE payloads, or navigation behavior.
- Adding motion-based wake, auto-pause, crash detection, or screen rotation.
- Shutting down a shared PMU rail used by other Waveshare peripherals.
- Broader Wi-Fi, display, BLE, or CPU-frequency power tuning.

## Rollback

GPS rollback is limited to restoring `HAS_HARDWARE_GPS` for a target that gains
a physical receiver. IMU diagnostics can be restored for a dedicated build by
defining `WAVESHARE_IMU_DIAGNOSTICS`; production should not require reverting
the shutdown implementation to troubleshoot the sensor.
