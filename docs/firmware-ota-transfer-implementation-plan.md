# Firmware OTA Transfer Implementation Plan

## Goal

Add a production-ready firmware update path where the iPhone app downloads a
signed firmware release, transfers it to the ESP32 over the existing local
device Wi-Fi path, and the ESP32 installs it through the inactive OTA partition.

The long-term design is to generalize the PR38 map-transfer plumbing into a
shared device-transfer layer, then implement map transfer and firmware OTA as
separate protocols on top of that layer.

## Design Principles

- Keep internet access, GitHub release downloads, TLS, and large-file caching on
  iOS.
- Keep ESP32 update installation local, deterministic, and boot-safe.
- Use BLE only for authenticated control/status. Use Wi-Fi/HTTP for bulk data.
- Reuse the existing ESP32 SoftAP/iOS join flow, but do not reuse the map
  upload endpoint for firmware writes.
- Build and publish target-specific firmware images for each supported board
  target. The 1.75 and 2.06 Waveshare devices should not share one OTA binary
  unless the firmware is later refactored for safe runtime board detection.
- Treat firmware as security-sensitive: verify integrity before upload and
  before boot, and prefer signed release metadata over unsigned hashes.
- Preserve USB flashing as the recovery path for bootloader, partition-table,
  or unrecoverable application failures.

## Current Baseline

PR38 established the right transfer shape for large payloads:

- iOS sends authenticated BLE commands to enter/exit transfer mode and request
  status.
- ESP32 starts a temporary SoftAP when needed and exposes a local HTTP server.
- iOS joins the device network with `NEHotspotConfiguration`.
- Maps upload through local HTTP session endpoints, then activate asynchronously.
- Map installation validates staged files before publishing them to the active
  SD-card layout.

Firmware OTA should share the transfer-mode lifecycle and Wi-Fi join logic, but
must use a firmware-specific HTTP API that streams into the inactive OTA app
partition instead of staging files on SD.

## Target User Flow

1. iOS checks the firmware update manifest from GitHub Pages or another stable
   HTTPS endpoint.
2. iOS compares the manifest target/version/build against the connected device
   status reported over BLE.
3. iOS downloads the firmware image from GitHub Releases.
4. iOS verifies the downloaded image against the signed manifest.
5. User confirms update in the app.
6. iOS sends an authenticated BLE command to enter firmware-transfer mode.
7. ESP32 enables the shared local transfer server and reports `baseUrl`, SSID,
   firmware status, and a short-lived session token.
8. iOS joins the device SoftAP if needed.
9. iOS uploads the firmware image over local HTTP.
10. ESP32 writes the image to the inactive OTA partition and verifies it.
11. iOS asks ESP32 to finalize the update.
12. ESP32 marks the new app partition bootable and reboots.
13. New firmware performs boot health checks and marks the image valid.
14. iOS reconnects over BLE and reports success or rollback state.

## Shared Device Transfer Layer

Create a reusable transfer service instead of keeping transfer logic named only
for maps.

### ESP32

Add `esp32/lib/device_transfer/`:

- Owns Wi-Fi mode transitions, temporary SoftAP lifecycle, HTTP server lifecycle,
  shared status, and last-error reporting.
- Uses one shared local HTTP server and port for all transfer features. Feature
  handlers are selected by path, for example `/map-transfer/...` and
  `/firmware-update/...`.
- Supports transfer modes:
  - `none`
  - `map`
  - `firmware`
- Generates a short-lived session token when transfer mode starts.
- Exposes common status JSON:

```json
{
  "enabled": true,
  "mode": "firmware",
  "baseUrl": "http://192.168.4.1:8080",
  "apSsid": "BikeComputer-Transfer",
  "sessionToken": "opaque-short-lived-token",
  "lastError": null
}
```

Map transfer can continue to serve `/map-transfer/...`; firmware OTA gets its
own `/firmware-update/...` endpoints. The shared layer routes requests by path
to the active feature handler on the same HTTP server and port. This keeps the
iOS network join/reachability flow stable while allowing feature-specific
protocols and state machines.

### iOS

Add a `DeviceTransferManager`:

- Sends BLE transfer commands.
- Waits for transfer status.
- Joins the ESP32 SoftAP.
- Verifies local HTTP reachability.
- Owns common timeout/error handling.
- Provides `DeviceTransferSession` with `baseURL`, `mode`, and session token.

Refactor `OfflineMapManager` to use `DeviceTransferManager` for setup/teardown,
while leaving map packaging and map activation in the map-specific code.

## BLE Protocol Additions

Extend the authenticated BLE control/status channel with generic transfer
commands while preserving map compatibility during migration.

Recommended commands:

| Prefix | Direction | Payload | Meaning |
| --- | --- | --- | --- |
| `DTRN` | iOS -> ESP32 | `enter|map` | Enter map transfer mode. |
| `DTRN` | iOS -> ESP32 | `enter|firmware` | Enter firmware update transfer mode. |
| `DTRN` | iOS -> ESP32 | `exit` | Exit any active transfer mode. |
| `DSTS` | iOS -> ESP32 | empty | Request generic transfer status. |
| `DSTS` | ESP32 -> iOS | UTF-8 JSON | Generic transfer status notification. |

Keep `MTRN`/`MSTS` as aliases for map transfer until the iOS and ESP32 releases
using the generic protocol are broadly installed.

Firmware status should include:

```json
{
  "deviceVersion": "0.3.0",
  "build": 42,
  "target": "WAVESHARE_AMOLED_175",
  "otaState": "valid",
  "runningPartition": "ota_0",
  "nextPartition": "ota_1",
  "firmwareUpdate": {
    "status": "idle",
    "receivedBytes": 0,
    "totalBytes": 0,
    "sha256": null,
    "error": null
  }
}
```

## Firmware HTTP API

Use a firmware-specific API. Do not put firmware bytes into map staging paths.

### `GET /firmware-update/status`

Returns current OTA state:

```json
{
  "status": "idle",
  "target": "WAVESHARE_AMOLED_175",
  "runningVersion": "0.3.0",
  "runningBuild": 42,
  "runningPartition": "ota_0",
  "inactivePartition": "ota_1",
  "maxImageBytes": 3145728,
  "receivedBytes": 0,
  "totalBytes": 0,
  "sha256": null,
  "lastError": null
}
```

### `POST /firmware-update/begin`

Body:

```json
{
  "schemaVersion": 1,
  "version": "0.4.0",
  "build": 43,
  "target": "WAVESHARE_AMOLED_175",
  "gitSha": "abc123",
  "size": 2178944,
  "sha256": "hex",
  "minUpdaterProtocol": 1,
  "manifestSignature": "base64",
  "releaseUrl": "https://github.com/...",
  "allowDowngrade": false
}
```

Behavior:

- Validate target, version/build policy, size, and signature.
- Reject downgrades by default. Allow them only when the iOS app sends
  `allowDowngrade: true` from a developer-only flow and the image is otherwise
  signed, target-matched, and valid.
- Ensure image fits the inactive OTA partition.
- Initialize OTA writer with `esp_ota_begin`.
- Move status to `receiving`.

### `PUT /firmware-update/image`

Uploads the firmware image body.

Recommended v1 behavior:

- Accept one full-image upload with `Content-Length`.
- Stream request body directly into `esp_ota_write`.
- Compute SHA-256 while streaming.
- Reject unexpected size or hash mismatch.
- Move status to `received` when complete.

Full retry is acceptable for v1 because the firmware image should be small
enough to transfer quickly over local Wi-Fi. Do not implement resumable chunk
uploads in v1; restart the full image upload after interruption.

### `POST /firmware-update/finalize`

Behavior:

- Call `esp_ota_end`.
- Verify image descriptor target/version compatibility.
- Mark the inactive partition bootable with `esp_ota_set_boot_partition`.
- Return `202 Accepted`.
- Reboot after a short delay so iOS receives the response.

### `POST /firmware-update/cancel`

Abort an in-progress upload, call OTA cleanup, and return status to `idle`.

## Firmware Image Metadata

Embed firmware identity in the app image:

- target/environment, for example `WAVESHARE_AMOLED_175`
- semantic version for user-facing release identity
- monotonically increasing build number for update ordering
- git SHA
- build timestamp
- protocol version

Use both semantic version and build number. The semantic version is what users
see. The build number is the authoritative ordering key for normal update
checks, with explicit developer-downgrade support as described above.

Expose this metadata over BLE status so iOS can decide whether an update
applies.

## Release Hosting

Use GitHub-native release hosting:

- GitHub Actions builds firmware on tags and pull requests.
- PR builds compile both target environments to catch regressions:
  - `WAVESHARE_AMOLED_175`
  - `WAVESHARE_AMOLED_206`
- Tagged builds attach target-specific firmware assets to GitHub Releases:
  - `WAVESHARE_AMOLED_175.bin`
  - `WAVESHARE_AMOLED_206.bin`
- The workflow computes SHA-256 and signs one manifest per target.
- GitHub Pages hosts each latest manifest at a stable target-specific HTTPS URL:
  - `/firmware/WAVESHARE_AMOLED_175/manifest.json`
  - `/firmware/WAVESHARE_AMOLED_206/manifest.json`

Example manifest:

```json
{
  "schemaVersion": 1,
  "target": "WAVESHARE_AMOLED_175",
  "version": "0.4.0",
  "build": 43,
  "gitSha": "abc123",
  "size": 2178944,
  "sha256": "hex",
  "url": "https://github.com/seichris/open-bike-computer/releases/download/v0.4.0/WAVESHARE_AMOLED_175.bin",
  "minUpdaterProtocol": 1,
  "signature": "base64"
}
```

iOS should verify the signature before offering the update. ESP32 should verify
the same manifest fields and image hash before finalizing the OTA write.

The iOS app must choose the manifest from the connected device's reported
`target`. The ESP32 must reject any manifest or image whose target does not
match its compiled firmware target.

## Security Model

Minimum acceptable security:

- BLE transfer commands require the existing authenticated session.
- The v1 SoftAP can remain open. This is acceptable because transfer mode is
  short-lived, entered only through authenticated BLE control, and firmware trust
  comes from target-matched signed manifests plus image hash verification rather
  than Wi-Fi secrecy.
- Firmware transfer mode returns a short-lived session token.
- Every firmware HTTP request includes `X-BikeComputer-Transfer-Token`.
- iOS verifies the signed manifest before upload.
- ESP32 verifies target, size, SHA-256, and signature before finalization.
- ESP32 refuses cross-target images.

Manifest signing:

- Generate a P-256 signing key for release manifests. P-256 is used here because
  it is supported by both Python `cryptography` in GitHub Actions and Apple's
  CryptoKit verifier in the iOS app.
- Store the public key in firmware and iOS.
- Store the private key only in GitHub Actions secrets or an offline release
  process.

Do not rely on obscured GitHub URLs, local AP isolation, or SHA-256 alone as the
long-term trust boundary.

## ESP32 Implementation Tasks

1. Add firmware version/build metadata constants and BLE status reporting.
2. Add `device_transfer` shared server/lifecycle layer.
3. Move map-transfer Wi-Fi/HTTP lifecycle into `device_transfer` while keeping
   map-specific endpoints and installer behavior intact.
4. Add generic BLE transfer commands and keep `MTRN`/`MSTS` compatibility.
5. Add `firmware_update` OTA state machine using ESP-IDF OTA APIs.
6. Add `/firmware-update/status`, `/begin`, `/image`, `/finalize`, and
   `/cancel` endpoints.
7. Add SHA-256 streaming verification, target/build checks, and
   developer-controlled downgrade allowance.
8. Enable boot validation and rollback handling:
   - mark the new app valid only after core boot checks pass.
   - report pending/rollback state over BLE.
9. Add serial logs with stable error codes for every OTA failure path.

## iOS Implementation Tasks

1. Add `DeviceTransferManager` and `DeviceTransferSession`.
2. Refactor offline map transfer to use the shared manager.
3. Add `FirmwareReleaseManifest` model and signature/hash verification.
4. Add `FirmwareUpdateManager`:
   - check latest manifest.
   - compare against connected device metadata.
   - download firmware with progress.
   - verify downloaded image.
   - enter firmware transfer mode.
   - upload image over local HTTP.
   - finalize and wait for BLE reconnect.
5. Add Settings UI for:
   - current firmware version/build.
   - available update.
   - update progress.
   - post-reboot success/failure.
6. Add a developer-only downgrade toggle or action. Downgrade must still require
   a signed, target-matched release image.
7. Persist update state so the app can resume status checks after foregrounding
   or device reboot.

## GitHub Actions Tasks

1. Add an ESP32 firmware build workflow for:
   - `WAVESHARE_AMOLED_175`
   - `WAVESHARE_AMOLED_206`
2. Build on PRs to catch compile regressions.
3. Build on version tags and upload target-specific `.bin` release assets.
4. Generate SHA-256 metadata.
5. Sign target-specific manifests.
6. Publish/update target-specific GitHub Pages manifests.
7. Keep release artifacts target-specific and avoid ambiguous asset names.

## Validation Plan

### Unit/Protocol Tests

- iOS manifest parsing, version comparison, and signature verification.
- iOS transfer URL construction and token headers.
- ESP32 path parsing, token validation, and size/hash validation.
- Firmware target mismatch rejection.
- Normal version/build update ordering and developer downgrade allowance.

### Integration Tests

- Existing map transfer still works after the shared transfer refactor.
- Firmware update succeeds from iPhone over ESP32 SoftAP.
- Interrupted upload leaves the device on the old firmware.
- Hash mismatch is rejected and old firmware remains active.
- Wrong target image is rejected.
- Developer downgrade to an older signed build succeeds only through the
  developer flow.
- App reconnects after reboot and reports updated version.
- New firmware marks itself valid only after health checks.

### Hardware Tests

- Waveshare ESP32-S3 AMOLED 1.75 with SD card inserted.
- Waveshare ESP32-S3 AMOLED 1.75 without SD card inserted.
- Waveshare ESP32-S3 AMOLED 2.06 with target-matched firmware.
- Cross-target update attempt from 1.75 to 2.06 firmware and 2.06 to 1.75
  firmware.
- iPhone foreground update.
- iPhone lock/foreground interruption during upload.
- Poor signal or forced Wi-Fi disconnect during upload.
- USB recovery after intentionally bad test image.

## Rollout Sequence

1. Land shared transfer refactor with no firmware OTA behavior change.
2. Land firmware metadata and status reporting.
3. Land firmware HTTP endpoints behind a developer-only UI flag.
4. Add GitHub Actions release artifact generation.
5. Add iOS update check/download/verify path.
6. Enable firmware upload/finalize for developer builds.
7. Field test rollback and interruption behavior.
8. Promote to normal Settings UI after repeated successful hardware updates.
