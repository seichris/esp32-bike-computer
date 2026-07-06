# Device Screen Selection Implementation Plan

## Goal

Allow the iOS app to configure which main screens are available on the ESP32
device and which screen is shown by default when the main UI starts.

Current device screens on `main`:

- Map
- Navigation instruction
- Ride stats
- Map guidance

The firmware should still be usable without iOS configuration. If no setting has
been received, the current behavior should remain equivalent to enabling all
screens and starting on Map.

## User-Facing Behavior

In the iOS app settings, add a Device Screens section with:

- A toggle for each device screen.
- A default screen picker containing only enabled screens.

Rules:

- At least one screen must remain enabled.
- If the current default screen is disabled, select the first enabled screen.
- If a saved/default screen is invalid on firmware, fall back to Map if enabled,
  otherwise the first enabled screen.
- Cycling on the device should skip disabled screens.
- Direct device controls that currently call `toggleNavigationScreen()` should
  use the same enabled-screen cycle.

## BLE Protocol

Reuse the existing `2A73` map/settings characteristic and `MSET` fallback path.

Add setting IDs:

| ID | Meaning | Range |
| --- | --- | --- |
| `12` | Enabled main screens mask | bit 0 Map, bit 1 Navigation, bit 2 Ride Stats, bit 3 Map Guidance |
| `13` | Default main screen | `0` Map, `1` Navigation, `2` Ride Stats, `3` Map Guidance |

Do not use the firmware `tileName` enum values directly in the BLE protocol.
That enum has legacy values and may change for internal compatibility. Define a
small stable protocol enum for screen settings on both iOS and firmware.

Recommended defaults:

```text
enabledScreensMask = 0b1111
defaultScreen = 0
```

## Firmware Plan

### 1. Add Stable Screen Setting Types

In the ESP32 firmware, add stable protocol constants near the BLE settings code:

```cpp
enum DeviceScreenSetting : uint8_t {
  DEVICE_SCREEN_MAP = 0,
  DEVICE_SCREEN_NAVIGATION = 1,
  DEVICE_SCREEN_RIDE_STATS = 2,
  DEVICE_SCREEN_MAP_GUIDANCE = 3,
};
```

Add helpers to translate from this protocol enum to `tileName`.

### 2. Extend Persisted Settings

Add fields to the settings structure used by `ble_navigation`:

```cpp
uint8_t enabledScreensMask = 0x0F;
uint8_t defaultScreen = DEVICE_SCREEN_MAP;
```

Persist in NVS under the existing `mapSettings` namespace, for example:

- `screenMask`
- `defaultScreen`

When loading:

- Clamp `enabledScreensMask` to supported bits.
- If the result is zero, reset to all supported screens.
- Clamp or validate `defaultScreen`.
- If default is not enabled, choose a fallback.

### 3. Handle Setting IDs 12 and 13

Extend `applyMapSetting`:

- ID `12`: update `enabledScreensMask`, persist, and if the active screen is no
  longer enabled, switch to the configured fallback.
- ID `13`: update `defaultScreen`, persist after validation, and optionally
  switch immediately only if product wants live preview. Initial implementation
  should persist only and leave the current active screen unchanged.

Validation must not allow zero enabled screens.

### 4. Centralize Screen Selection Helpers

In `mainScr.cpp`, add helpers such as:

```cpp
static tileName tileForDeviceScreen(uint8_t screen);
static uint8_t deviceScreenForTile(tileName tile);
static bool isScreenEnabled(tileName tile);
static tileName fallbackScreen();
static tileName nextEnabledScreen(tileName current);
```

Use these helpers from:

- `showNextMainScreen()`
- `toggleNavigationScreen()`
- setting ID `12` live active-screen correction
- startup/default screen selection

Keep existing behavior for unsupported screens like `COMPASS` and `SATTRACK`.
They should not become part of this iOS-configurable main cycle unless product
explicitly adds them later.

### 5. Apply Default Screen on Startup

The startup path currently forces Map in `loadMainScreen()`/`createMainScr()`.
Change it so after the main screen exists and map sprites are created, firmware
calls the same `showMainTile(defaultTile)` path used by runtime cycling.

Be careful with map sprite creation:

- The map canvas is parented to `mapTile`.
- Map-backed screens are Map and Map Guidance.
- If the default is Navigation or Ride Stats, the map canvas can still exist but
  the visible tile should be the configured default.

### 6. Preserve Map Guidance Semantics

The Map Guidance screen must keep its current invariants:

- Dragging disabled.
- `followGps` forced true.
- North-up when no route is loaded.
- Course-up when route geometry exists.
- Bottom navigation overlay visible only in Map Guidance mode.

Enabled-screen cycling must not bypass those entry actions; it should call
`showMainTile(MAP_GUIDANCE)` rather than mutating `activeTile` directly.

## iOS Plan

### 1. Add Screen Setting Model

In `BLEManager`, add stable values matching the BLE protocol, not firmware enum
values:

```swift
enum DeviceScreen: Int, CaseIterable, Identifiable {
    case map = 0
    case navigation = 1
    case rideStats = 2
    case mapGuidance = 3
}
```

Add published properties:

```swift
@Published var enabledDeviceScreens: Set<DeviceScreen>
@Published var defaultDeviceScreen: DeviceScreen
```

If a `Set` binding becomes awkward in SwiftUI/UserDefaults, store the mask as an
`Int` internally and expose small helpers:

```swift
func isDeviceScreenEnabled(_ screen: DeviceScreen) -> Bool
func setDeviceScreen(_ screen: DeviceScreen, enabled: Bool)
```

### 2. Persist iOS Defaults

Add UserDefaults keys:

- `deviceSettings.enabledScreensMask`
- `deviceSettings.defaultScreen`

Defaults:

- enabled mask `0x0F`
- default `.map`

When loading or saving, apply the same validation as firmware:

- At least one enabled screen.
- Default must be enabled.
- Unknown bits ignored.

### 3. Send BLE Settings

Add:

```swift
func sendEnabledScreensMask()
func sendDefaultDeviceScreen()
```

These should call:

```swift
sendSetting(id: 12, value: Int32(mask))
sendSetting(id: 13, value: Int32(defaultScreen.rawValue))
```

Because `sendSetting` already saves settings and handles unsupported BLE state,
the new controls inherit the existing offline/local-save behavior.

### 4. Settings UI

Add a `Device Screens` section near the existing Screen Navigation section:

- Toggle rows:
  - Map
  - Navigation
  - Ride Stats
  - Map Guidance
- Picker:
  - Default Screen

UI validation:

- Disable the last enabled screen's toggle, or re-enable it immediately if the
  user tries to turn it off.
- Picker options should include enabled screens only.
- If toggling off the current default, update default before sending settings.

Send order when a toggle changes:

1. Update local mask and default fallback.
2. Send enabled mask.
3. If default changed, send default screen.

### 5. Optional Copy

Use concise names:

- `Map`
- `Navigation`
- `Ride Stats`
- `Map Guidance`

Avoid explaining the screens inline. The surrounding settings page already uses
short operational labels.

## Documentation Updates

Update `docs/ble-protocol.md`:

- Add setting IDs `12` and `13`.
- Document bit mapping and stable screen enum.
- State that firmware falls back to Map or first enabled screen if settings are
  invalid.

## Test Plan

### Firmware

Add native/unit coverage where practical for pure helpers:

- `enabledScreensMask = 0` normalizes to all supported screens.
- disabled current screen falls back to an enabled screen.
- `showNextMainScreen()` skips disabled screens.
- single enabled screen cycles to itself.
- default screen disabled falls back deterministically.
- protocol screen IDs translate correctly to `tileName`.

If the current ESP32 code does not expose testable pure helpers, put the mask
normalization and next-screen logic in a small helper module to avoid LVGL in
unit tests.

Run:

```sh
pio run -d esp32 -e WAVESHARE_AMOLED_175
```

### iOS

Extend `NavigationProtocolTests` or add focused BLEManager settings tests:

- screen mask persists across `BLEManager` reloads.
- default screen persists across reloads.
- disabling default changes default to first enabled screen.
- last enabled screen cannot produce a zero mask.
- setting IDs `12` and `13` are sent with expected values.

Run the existing iOS test command used by CI.

### Manual Device Checks

With a paired device:

1. Enable all screens, set default Map, reboot device. Verify Map appears.
2. Disable Navigation, cycle screens. Verify Navigation is skipped.
3. Enable only Map Guidance, cycle screens. Verify it stays on Map Guidance.
4. Set default Ride Stats, reboot. Verify Ride Stats appears.
5. Disable current default. Verify app selects a new default and device remains
   on a valid screen.
6. Start and stop navigation while Map Guidance is enabled. Verify stale turn
   instructions do not remain after route clear.

## Rollout Notes

- Old firmware will ignore setting IDs `12` and `13`; the iOS app should still
  save them locally.
- New firmware with old iOS defaults to all screens and Map startup.
- Keep the stable BLE screen enum separate from `tileName` to avoid protocol
  breakage if internal screen ordering changes.
- Do not remove `tapToSwitchScreens`; it remains the control for whether short
  taps cycle screens at all. The new mask only controls which screens are in the
  cycle and startup default.
