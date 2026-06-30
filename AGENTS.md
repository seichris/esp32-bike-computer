# Agent Notes (esp32-bike-computer)

This repo contains:
- `esp32/`: ESP32-S3 firmware (PlatformIO + Arduino + LVGL + NimBLE), currently based on the local IceNav-v3 map-renderer snapshot.
- `ios-app/`: iOS companion app (SwiftUI + MapKit + CoreBluetooth + HealthKit).
- `OSM_Extract/`: offline vector-map build pipeline (Docker-based).
- `waveshare_test/`: hardware bring-up sketches for the Waveshare board.

## Quick commands

### ESP32 (PlatformIO)

- Build: `cd esp32 && pio run`
- Flash: `cd esp32 && pio run -t upload`
- Serial monitor: `cd esp32 && pio device monitor -b 115200`
- List ports (macOS): `pio device list` or `ls /dev/cu.usbmodem*`

Bootloader mode: if upload fails, hold **BOOT (GPIO0)** while re-plugging USB.
For Python/pyserial captures on `/dev/cu.usbmodem*`, open at `115200` and set
`ser.dtr = False` plus `ser.rts = False` immediately after opening. Leaving
RTS/DTR asserted can reset or hold the ESP32-S3 USB serial path and produce an
empty monitor.

### iOS

- Open: `ios-app/BikeComputer/BikeComputer.xcodeproj`
- Real-device testing / trust / sharing notes: `ios-app/README.md`

## BLE contract

Current firmware implements BLE service UUID
`9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800` in `esp32/lib/ble_navigation/`.
The full protocol is documented in `docs/ble-protocol.md`.

Core navigation characteristic:
- Characteristic UUID `2A6E` (write without response)
- Payload (UTF-8): `IconID|DistanceMeters|Instruction`

Map-view characteristics:
- Route geometry UUID `2A6F`
- GPS position UUID `2A72`
- Map settings UUID `2A73`
- Auth UUID `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002`

If you add/remove/rename BLE characteristics, update both:
- `esp32/lib/ble_navigation/ble_navigation.cpp`
- `esp32/lib/ble_navigation/ble_navigation.hpp`
- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`

## Hardware gotchas (Waveshare ESP32-S3-Touch-AMOLED-1.75)

Definitive pinout + quirks: `WAVESHARE_HARDWARE.md`

Highlights:
- Display power must be enabled via **AXP2101** (I2C `0x34`) or the screen stays black.
- Touch reset is via **TCA9554 P0** (I2C `0x20`) — do **not** toggle GPIO20 (USB D+).
- SD card is SPI on `CS=41, MOSI=1, MISO=3, SCK=2` (firmware uses HSPI to avoid the display QSPI bus).
- Touch input is interrupt-gated on CST9217 `INT=GPIO21`; do not return to rapid polling. Arduino Core 3.x `Wire.requestFrom()` failures against the CST9217 can crash the I2C ISR if reads are attempted while no touch data is ready.

## Offline maps (OSM_Extract)

Preferred workflow is Docker:
- `cd OSM_Extract && docker compose run --rm tools bash`
- Run scripts from `/scripts` in the container; outputs land in `OSM_Extract/maps/` on the host.

Config:
- feature selection: `OSM_Extract/conf/conf_extract.yaml`
- styling: `OSM_Extract/conf/conf_styles.yaml`

## Change hygiene

- Keep edits focused: avoid sweeping refactors/reformatting.
- Keep the restored IceNav-derived renderer architecture intact unless a task explicitly targets a refactor.
- When touching LVGL/display code, preserve the “full screen buffer + full_refresh” strategy unless you have a measured reason to change it (it was chosen to avoid partial-update corruption on this AMOLED panel).
