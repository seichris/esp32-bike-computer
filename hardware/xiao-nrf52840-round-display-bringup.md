# XIAO nRF52840 Round Display Bring-Up

This note tracks Milestone 0 for the XIAO nRF52840 + Seeed Studio Round Display
target. It is hardware evidence, not firmware architecture.

## Current Status

- Branch: `xiao-round-display`
- Date checked: 2026-07-03
- XIAO nRF52840 connected: no
- Detected USB serial device: `/dev/cu.usbmodem2101`
- Detected device identity: Espressif `USB JTAG/serial debug unit`,
  `VID:PID 303A:1001`
- Milestone 0 exit status: not passed. The connected board is the existing ESP32
  board, so the XIAO Round Display vendor hardware test has not been uploaded
  or serial-verified yet.
- Milestone 1 repo skeleton: builds locally for `xiao_nrf52840_round`; upload
  and serial heartbeat verification are pending a connected XIAO board.
- Repo firmware uses Seeed_GFX setup 501 for the GC9A01 display backend; LCD
  output is compile-verified but not visually verified.
- Repo firmware exposes `SDLS / 24` for a bounded microSD directory listing
  once vendor hardware proof is complete.

## Required Hardware

- Seeed Studio XIAO nRF52840, non-Sense for the first product path.
- Seeed Studio 1.28-inch Round Display for XIAO.
- FAT32 microSD card, 32 GB or smaller.
- Optional but recommended for RTC validation: CR927 coin cell.
- Optional for battery validation: 3.7 V LiPo connected through the Round
  Display battery connector.

## Official Baseline

Use Seeed's `HardwareTest` example as the first proof firmware:

- Arduino IDE path: `File -> Examples -> Seeed Arduino Round display -> HardwareTest`
- Add `driver.h` beside the `.ino` with:

```cpp
#define BOARD_SCREEN_COMBO 501
```

Seeed's current compatibility table says the HardwareTest demo works on the
XIAO nRF52840 non-mbed core with the TFT library, and on the mbed core with
Arduino GFX. For this repo, prefer the non-mbed XIAO nRF52840 path first
because it is the least surprising path for Bluefruit-style Arduino BLE work.

## Pin Confirmation

| Function | XIAO pin |
| --- | --- |
| Battery voltage ADC | `D0/A0` |
| LCD chip select | `D1` |
| microSD chip select | `D2` |
| LCD data/command | `D3` |
| I2C SDA for touch/RTC | `D4/SDA` |
| I2C SCL for touch/RTC | `D5/SCL` |
| Display backlight | `D6` |
| Touch interrupt | `D7` |
| SPI SCK | `D8/SCK` |
| SPI MISO | `D9/MISO` |
| SPI MOSI | `D10/MOSI` |

Round Display v1.1 has a switch that controls whether `A0` and `D6` are used by
the battery-voltage and backlight circuits or released as normal XIAO pins. For
the bike-computer target, start with the switch in the position that enables
battery voltage and backlight control.

## Upload And Serial Procedure

1. Plug the XIAO nRF52840 into the Round Display headers.
2. Insert a FAT32 microSD card.
3. Install the RTC coin cell if validating RTC retention.
4. Toggle the Round Display switch ON.
5. Plug the XIAO USB-C cable into the Mac.
6. Confirm the device is not the ESP32 board:

```sh
ls /dev/cu.usbmodem*
system_profiler SPUSBDataType | rg -n "XIAO|Seeed|nRF|JTAG|serial|Product ID|Vendor ID|BSD Name" -C 3
```

7. Build and upload Seeed's `HardwareTest` example through Arduino IDE first.
8. Open serial at `115200`.

If upload fails, double-tap reset to enter the XIAO bootloader, then retry the
upload on the bootloader serial port. Do not use repo firmware as hardware
proof until the vendor example proves the hardware.

## Milestone 0 Exit Evidence

Paste a serial log here after the XIAO is connected and `HardwareTest` runs.
The log must prove all items below on the same hardware session. Validate the
captured log before marking Milestone 0 passed:

```sh
python3 xiao-nrf52840/tools/hardware_bringup_check.py /tmp/xiao-hardware-bringup.log
```

If Seeed's vendor example uses different wording, add explicit marker lines to
the capture in this form after verifying the behavior on the bench:

```text
EVIDENCE board_identity=pass
EVIDENCE vendor_display=pass
EVIDENCE vendor_touch=pass
EVIDENCE vendor_rtc=pass
EVIDENCE vendor_battery=pass
EVIDENCE vendor_sd=pass
EVIDENCE repo_lcd_init=pass
EVIDENCE repo_lcd_boot=pass
EVIDENCE repo_lcd_map=pass
EVIDENCE repo_touch_start=pass
EVIDENCE repo_touch_gesture=pass
```

Required evidence:

- Connected board identity shows Seeed XIAO nRF52840, not the ESP32-S3 board.
  The checker fails logs that include ESP32-S3 board evidence, Espressif USB
  JTAG/serial debug unit evidence, or the current wrong-board `VID:PID
  303A:1001`.
- Display init completed.
- Touch event detected.
- RTC read completed.
- Battery ADC read completed.
- microSD mounted and read/write test completed in the vendor example.
- Repo firmware `SDLS / 24` prints a bounded 32 GB FAT32 card directory
  listing after the XIAO target is uploaded.
- Repo firmware boot/status text and route/map line primitives are visible on
  the round LCD after the XIAO target is uploaded.
- Repo firmware logs touch start coordinates and tap/long/swipe gestures after
  the XIAO target is uploaded.

Capture checklist:

1. Save the USB identity output and the vendor `HardwareTest` serial output in
   the same raw log file.
2. Add explicit `EVIDENCE ...=pass` marker lines only after observing the
   corresponding behavior on the bench.
3. Flash the repo firmware, run `SDLS / 24`, switch to the route/map page, draw a
   route preview, and perform tap/long/swipe gestures.
4. Append the repo serial output to the same raw log file and run the checker.

Raw log template:

```text
# Paste system_profiler / USB identity lines here.
# Paste Seeed HardwareTest serial lines here.
EVIDENCE board_identity=pass
EVIDENCE vendor_display=pass
EVIDENCE vendor_touch=pass
EVIDENCE vendor_rtc=pass
EVIDENCE vendor_battery=pass
EVIDENCE vendor_sd=pass

# Paste repo firmware serial lines here after uploading xiao_nrf52840_round.
# Required examples include:
# MapLite: SD list path=/ entries=<n> truncated=<0|1> error=0
# DisplayRound: Seeed_GFX GC9A01 init complete
# DisplayRound: boot screen drawn
# DisplayRound: map frame route lines=<n> ... elapsed_ms=<ms>
# RoundUi: touch start x=<x> y=<y>
# RoundUi: gesture=<tap|long|left|right|up|down>
```

## References

- Seeed Round Display getting started:
  https://wiki.seeedstudio.com/get_start_round_display/
- Seeed Round Display hardware usage:
  https://wiki.seeedstudio.com/seeedstudio_round_display_usage/
- Seeed XIAO nRF52840 PlatformIO setup:
  https://wiki.seeedstudio.com/xiao_nrf52840_with_platform_io/
- Seeed Round Display Arduino library:
  https://github.com/Seeed-Studio/Seeed_Arduino_RoundDisplay
