# Watch workout companion validation record

This is the release evidence ledger for the paired Apple Watch, iPhone, and
ESP32 workout companion. A checked result requires evidence from the exact build
identified below. Unit tests and Simulator results never satisfy a physical
criterion.

## Current baseline and candidate identity

| Field | Value |
| --- | --- |
| Baseline branch | `main` |
| Current GitHub main | `f37249b4cb9cb9c218c57a19b25fd87ce04cf9af` (PR #115; fetched 2026-07-22) |
| App release identity | iPhone and Watch targets both resolve to `1.1 (7)` on current main |
| Heart-rate-zone candidate | `agent/heart-rate-zones`, based directly on current main `f37249b4`; the exact PR head must replace this branch reference before final physical validation |
| Current-main build provenance | `/private/tmp/open-bike-main-ios-watch-f37249b4-dd/Build/Products/Release-iphoneos/BikeComputer.app`, built from clean detached current main `f37249b4` with Xcode 26.6; strict deep signature verification, embedded-Watch validation, version inspection, entitlements, and bundled privacy-manifest comparison passed, 2026-07-22 |
| iPhone build | Current-main `1.1 (7)` Release app installed over USB on an iPhone 16 Pro Max (`00008140-001055643C81401C`) running iOS 26.5.2, 2026-07-22; launch and on-device version query were not repeated in this pass |
| Watch build | Current-main embedded `1.1 (7)` Watch app installed on an Apple Watch Series 8 (`00008301-D09E23AC3A0BC02E`) running watchOS 26.5, 2026-07-22; the user confirmed the app is present on the Watch; live workout launch remains pending |
| Last archived candidate | Historical only: `/tmp/open-bike-watch-companion-1.1-6-6cf57f33-20260720.xcarchive` at `6cf57f33` / `1.1 (6)`. Do not use its physical results as exact-current-main evidence. |
| ESP32 1.75 firmware | Current-main build/flash pending. Historical artifact: SHA-256 `1eb6233f77f46ed34deccdca87c5d600b2401b1c9547276ab2d4a854d2c90701` from `6cf57f33`, flashed 2026-07-20. |
| ESP32 2.06 firmware | Current-main build/flash pending. Historical artifact: SHA-256 `37c7dacd5cd68826b86f81d098d6a0764ac00d0360ae3ad0481f50ab2bb4c8ed` from `6cf57f33`; physical flash was not performed. |

Record dates, OS versions, device models, firmware environment, and evidence
links or filenames with each executed run. Never copy results from a different
build into the final-candidate column. Evidence explicitly labeled historical
is context only and does not satisfy a current-baseline or PR-candidate gate.

## Automated and packaging gates

| Gate | Status | Evidence |
| --- | --- | --- |
| iOS 15 compatibility/typecheck | Passed | The follow-up candidate built the iPhone target with deployment target iOS 15 and the embedded watchOS 10 app under Xcode 26.6. The standalone contract runner also launched and passed after the revised labels, direct Watch start, and iPhone-to-Watch max-HR sync changes, 2026-07-22. |
| iOS workout unit tests | Passed on heart-rate-zone candidate | 36 tests, zero failures/skips, iPhone 17 Pro Simulator on iOS 26.5; xcresult `Test-WorkoutContractiOSTests-2026.07.22_12-40-42-+0800.xcresult`, 2026-07-22 |
| watchOS workout unit tests | Passed on heart-rate-zone candidate | 93 tests, zero failures/skips, including the production configured-zone snapshot path, Apple Watch Series 11 (46mm) Simulator on watchOS 26.5; xcresult `Test-WorkoutContractWatchTests-2026.07.22_12-41-09-+0800.xcresult`, 2026-07-22 |
| iOS device and Simulator builds with embedded Watch app | Passed for current-main baseline and candidate Simulator | Clean current main `f37249b4` produced a development-signed Release iPhone app with embedded Watch app and was installed on both physical devices. The heart-rate-zone candidate produced a clean unsigned Debug Simulator container with the embedded Watch app, 2026-07-22. |
| App Store release identity | Passed locally / pending editable version and upload | App Store Connect app `6788977349` had version 1.0 in `READY_FOR_DISTRIBUTION` and valid builds through 5 at the last authenticated check. Current main iPhone and Watch targets both resolve to marketing version 1.1 and build 7. Creating an editable 1.1 version and uploading remain separately authorized actions. |
| Signed Release integrity | Passed for current-main development build / archive and distribution export pending | Exact current-main `1.1 (7)` iPhone and embedded Watch bundles passed strict deep signature verification and metadata inspection, 2026-07-22. The last full archive/repository-verifier result remains historical at `6cf57f33`; create a fresh archive for the final PR head. |
| App Store distribution signing | Pending signing authority/assets | The iPhone bundle has an active App Store profile, but App Store Connect lists no Watch distribution profile and only a development certificate is available locally/remotely. Creating certificates/profiles or enabling provisioning updates requires separate authorization. |
| Installed-app launch smoke | Current-main install passed / launch pending | `1.1 (7)` was installed on the connected iPhone and paired Watch; the user confirmed the Watch app is present. Neither app launch was repeated for this exact-main pass, so launch remains pending, 2026-07-22. |
| `ValidateEmbeddedBinary` | Passed on current main | Exact current-main `f37249b4` development-signed Release build, 2026-07-22 |
| iPhone HealthKit entitlement | Passed in current-main signed Release build | `com.apple.developer.healthkit = true`, verified from the exact current-main `1.1 (7)` app, 2026-07-22 |
| Watch HealthKit entitlement | Passed in current-main signed Release build | `com.apple.developer.healthkit = true`, verified from the exact current-main embedded `1.1 (7)` Watch app, 2026-07-22 |
| Watch `workout-processing` background mode | Passed on current main | Exact current-main embedded Watch `Info.plist` contains `workout-processing` and targets companion `LetItRide.BikeComputer`, 2026-07-22 |
| iPhone and Watch privacy manifests in bundles | Passed on current main | Exact current-main bundle manifests match source byte-for-byte. SHA-256 remains `5f51c506726d785bedd75dba4181b6a564dc0d0ca72de58858242ade6a24842b` (iPhone) and `521eb6ef8430773e5c010e1838fe9dd8fa5d62b7b76d1cea8d7d8daadcb144e2` (Watch), 2026-07-22 |
| Watch app icon in bundle / asset validation | Passed on current main | Exact current-main Watch bundle contains compiled assets and `CFBundleIconName = AppIcon`; final installed-screen review remains part of the physical matrix. |
| In-app privacy-policy reachability | Passed automated / pending final tap | iPhone Settings and Watch start screen compile against one shared HTTPS URL, and the policy is now published on current main. Open it from the final installed PR build before submission. |
| App Store Connect privacy-policy URL | Configured / pending final tap and dashboard recheck | The documented public-main policy includes the Apple Watch, HealthKit, and 30-day retention text. App Store Connect displayed that GitHub URL at the last authenticated check; recheck the dashboard and tap the link from the final installed build before submission. |
| App Store Connect App Privacy declarations | Published but stale / submission blocker | The authenticated App Store Connect dashboard reports the declaration was published 11 days ago and currently shows only **Precise Location** under **Data Not Linked to You**, used for app functionality. Candidate code and `docs/app-store-privacy-disclosures.md` require Precise Location, Device ID, Other User Content, and Product Interaction, all linked to the installation identity and not used for tracking. Update, review the product-page preview, and publish those answers before submission; no dashboard mutation was made, 2026-07-20. |
| Production privacy retention/provider contract | Pending authenticated production/provider check | Candidate compose defaults and policy agree on 30-day artifact retention, scheduled deletion, and equivalent provider protection, and the public production health endpoint returned HTTP 200 on 2026-07-20. Exact deployed environment values and provider contractual obligations could not be authenticated through the available Coolify or SSH paths and remain required before submission. |
| Backend retention/privacy regressions | Passed | 206 backend tests passed (one unrelated skip) after integrating current main; the subsequent candidate changes do not touch backend code, 2026-07-20. |
| Workout protocol/vector/state/presenter host tests | Passed | Strict C++ protocol/state/presenter/GPS suites plus exact protected native channel-six dispatch, replay, and wrong-channel checks, 2026-07-20 |
| Existing navigation/BLE regression tests | Candidate typecheck passed / runtime host launch pending | The complete navigation/BLE host source set typechecked after the zone-availability flag rename, with only existing SDK deprecation warnings, 2026-07-22. The last full host-runtime pass remains historical at `6cf57f33`; the local host executable launch is currently blocked in macOS `dyld_start`. |
| `WAVESHARE_AMOLED_175` firmware build, flash, and boot | Historical pass / current-main refresh pending | The `6cf57f33` artifact passed its freeze regression and physical 1.75-inch flash on 2026-07-20. Rebuild and reflash the final PR head before using this row as current candidate evidence. |
| `WAVESHARE_AMOLED_206` firmware build | Historical build / current-main refresh pending | The `6cf57f33` artifact built successfully on 2026-07-20; the final PR head still needs a fresh 2.06 build and physical flash. |
| 1.75 and 2.06 layout/interaction host tests | Passed | Both `test_gui_layout.cpp` variants after current-main integration; the candidate changes do not touch layout code, 2026-07-20 |
| App Store iPhone screenshot export validation | Passed | Four opaque 1242x2688 PNGs plus manifest/contact sheet/source provenance/ZIP; candidate changes do not touch rendering inputs or derivatives, and generation/validation/provenance/package checks passed, 2026-07-20 |
| App Store Watch screenshot dimensions/alpha | Passed | Opaque 416x496 JPEG; `bun run validate:watch`, candidate changes do not touch the asset, 2026-07-20 |

## Physical-device matrix

| # | Scenario and required observation | Final-candidate status | Evidence |
| --- | --- | --- | --- |
| 1 | Start on Watch with iPhone foreground and ESP32 connected; one coherent session appears on all three. | Pending | — |
| 2 | Start on iPhone with a paired Watch and installed companion; start proceeds directly, the Watch wakes, and the Watch owns the workout. | Pending | — |
| 3 | Start without ESP32, connect it mid-workout, and receive the latest coherent state. | Pending | — |
| 4 | Disconnect and reconnect ESP32; Watch continues and ESP32 resynchronizes without stale replay. | Pending | — |
| 5 | Disable and restore Watch/iPhone Bluetooth; Watch continues and iPhone reconciles current state. | Pending | — |
| 6 | Lock/background iPhone while navigating; record end-to-end sample latency and p95. | Pending | — |
| 7 | Background iPhone without navigation; ESP32 must become honestly stale rather than show old speed as current. | Pending | — |
| 8 | Pause and resume from both Watch and iPhone; state agrees and paused time/distance do not inflate. | Pending | — |
| 9 | End and save once from Watch and once from iPhone in separate runs; each produces one synchronized terminal outcome. | Pending | — |
| 10 | With Apple's Workout active, start directly from Watch and iPhone in separate runs and verify any start failure or displacement is reported honestly. | Pending | — |
| 11 | Deny Health access, then deny Watch location separately; workout setup and unavailable route/GPS metrics remain honest. | Pending | — |
| 12 | Ride without external sensors; optional power/cadence stay unavailable and GPS fallback behavior is correct. | Pending | — |
| 13 | Ride with cycling speed, power, and cadence sensors; available values propagate without double counting. | Pending | — |
| 14 | Terminate/crash the Watch app during a workout; relaunch and recover the same session without duplicate save. | Pending | — |
| 15 | Save after outdoor movement; Health/Fitness shows exactly one workout with route, distance, energy, and heart rate. | Pending | — |
| 16 | Run at least two hours; record Watch, iPhone, and ESP32 battery deltas plus thermal observations. | Pending | — |
| 17 | Validate readable, unclipped live/stale/paused/ended/idle screens on physical 1.75- and 2.06-inch devices. | Pending | — |
| 18 | Configure maximum heart rate in iPhone Developer Settings, verify it syncs to Watch, start a ride, and confirm one fresh heart-rate sample produces the same expected zone on Watch, iPhone (`Zone N` / `heart zone`), and ESP32. Change max HR between rides and verify the boundary changes without being labeled as an Apple system zone. | Pending | User confirmed a live zone appeared in the iPhone app on 2026-07-22; setting sync, revised labels, boundary change, and full Watch/iPhone/ESP32 agreement remain pending. |

## Exact-build confirmation paths carried from Phase 3

These were not performed on the latest confirmation-UX build and remain part of
the final matrix even though an earlier build exercised adjacent paths:

- **Keep Riding** is a no-op and leaves the exact active session unchanged.
- Final **Discard Workout** confirmation saves no Health workout.
- **End and Save** creates exactly one Health workout.
- Ending navigation and ending the workout remain independent in both orders.
- A moving outdoor test saves and displays a route when permission is granted.

## Measurements

### Foreground latency

Capture at least 100 timestamp-correlated metric changes from Watch collection
through iPhone presentation and ESP32 presentation. Report sample count, median,
p95, maximum, clock method, and whether p95 is at most three seconds.

| Path | Samples | Median | p95 | Maximum | Pass |
| --- | ---: | ---: | ---: | ---: | --- |
| Watch to iPhone | — | — | — | — | Pending |
| Watch to ESP32 | — | — | — | — | Pending |

### Two-hour battery and thermal run

Start with recorded battery percentages and stable thermal state. Use a real
outdoor or representative moving ride with Watch workout, iPhone mirroring, and
ESP32 telemetry active. Record navigation state separately so results are
interpretable.

| Device | Start battery | End battery | Delta | Thermal observation |
| --- | ---: | ---: | ---: | --- |
| Apple Watch | — | — | — | Pending |
| iPhone | — | — | — | Pending |
| ESP32 / power source | — | — | — | Pending |

## Health/Fitness inspection

For the final outdoor save, record the workout start/end timestamps and inspect
Health/Fitness for:

- exactly one BikeComputer cycling workout;
- route present when location was permitted;
- distance and active energy present;
- heart rate present; any Apple system zone information shown by Fitness is
  independent of BikeComputer's live max-HR zones;
- the expected BikeComputer zone was observed separately on Watch, iPhone, and
  ESP32 during the live physical-zone check;
- source identified as the BikeComputer Watch app;
- no workout for the final confirmed discard run.

Redact personal route coordinates from committed evidence. Store private device
screenshots outside the repository or crop them so they disclose no home or
other sensitive location.

## Release decision

Release is blocked while any required row is Pending or Failed. The user may
elect to continue development while assuming a hardware path behaves as
designed, but an assumption does not convert that row into release evidence. If
optional external sensor hardware is unavailable, record that concrete blocker
rather than substituting simulated data. The ownership-capable app must be
available before ownership-v2 firmware, and App Store publication remains a
separate authorized action.
