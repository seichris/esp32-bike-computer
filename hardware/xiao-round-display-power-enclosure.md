# XIAO Round Display Power And Enclosure Notes

Status on 2026-07-03: repo-side firmware support exists, but hardware runtime,
thermal behavior, waterproofing, and vibration behavior are not measured because
the XIAO nRF52840 Round Display is not connected.

## Firmware Defaults

- Battery ADC pin: `D0/A0`.
- Backlight PWM pin: `D6`.
- ADC assumption: nRF52 internal 3.6 V range, 12-bit reads, 8-sample average.
- Battery-divider assumption: 2:1. This must be calibrated against a multimeter
  before battery percentage or low-battery thresholds are trusted.
- Auto-dim: after 30 seconds without touch or BLE activity.
- Screen-off backlight: after 120 seconds while disconnected and idle.
- Recovery path: touch activity or BLE activity restores the target brightness.

Round Display v1.1 has a switch that can release `A0` and `D6` as normal XIAO
pins. For bike-computer firmware validation, put the switch in the position that
enables battery voltage measurement and backlight control.

## Battery Runtime Test

Record these values for every runtime pass:

- Battery model, nominal capacity, and measured starting voltage.
- Display target brightness percentage.
- BLE state: disconnected, connected idle, or active navigation.
- Firmware commit/branch.
- Ambient temperature.
- Start time, low-battery warning time, screen-off/recovery behavior, and final
  voltage.
- Whether the display, BLE, touch, RTC, and serial diagnostics kept working.

Minimum useful tests:

1. USB powered, screen always on for 30 minutes.
2. Battery powered at 100% brightness until low-battery warning.
3. Battery powered at the intended outdoor brightness until low-battery warning.
4. Battery powered with auto-dim enabled during a simulated ride.
5. Disconnected idle recovery: wait until backlight-off, then wake by touch and
   by iOS reconnect.

## Thermal Check

During each battery test, measure the rear board area near the XIAO, charger IC,
and display flex area at start, 15 minutes, 30 minutes, and end. Do not enclose
the device until the hottest measured surface remains comfortable to touch under
the intended brightness and charging conditions.

## Mount And Enclosure Assumptions

- First mount should be a non-waterproof prototype that allows USB access,
  reset access, and visual inspection of the display-board battery switch.
- Do not pot or seal the board until battery runtime, charging heat, and RTC
  retention are measured.
- Leave clearance for the microSD card slot and XIAO USB-C connector.
- Avoid clamping the round touch glass or applying pressure to the display flex.
- Use vibration-isolating tape or gasket material between the PCB/display board
  and any rigid bike mount.
- Treat waterproofing as unvalidated until a sacrificial enclosure passes spray
  testing without condensation around USB, switch, display edge, or SD slot.

## Go/No-Go Gate

Outdoor use is a no-go until there is measured evidence for:

- Battery runtime at the chosen brightness.
- Low-battery behavior and clean recovery after recharge.
- Touch recovery from dim/off state.
- BLE reconnect after disconnected idle.
- No visible display fogging or water ingress after enclosure testing.
