# Watch workout companion validation record

This is the release evidence ledger for the paired Apple Watch, iPhone, and
ESP32 workout companion. A checked result requires evidence from the exact build
identified below. Unit tests and Simulator results never satisfy a physical
criterion.

## Candidate identity

| Field | Value |
| --- | --- |
| Branch | `feature/watchos-workout-companion` |
| Phase 6 base | `cf52c1a26d4068f72d45dab216fb27535a580f92` |
| Main integration checkpoint | `3b583669de7141c37f00d1f05713f46aced0fa1c` (includes `origin/main` / PR #111 at `e90118509d517bd34e0e5adabfb2f197fcd3ee23`) |
| Candidate code commit | `40b8e034a75045de51ffd974d2155144bfa2911e` |
| Signed-archive evidence checkpoint | `0c1f64526327ba764d2d3fe5a73aef23e9c46ac6` (only this ledger differs from candidate code commit) |
| iPhone build | Exact-candidate Apple Development-signed Release archive passed strict signature validation and was installed on an iPhone 16 Pro Max running iOS 26.5.2 through Xcode's paired network connection, 2026-07-20; pending final launch/matrix and App Store distribution export |
| Watch build | Exact-candidate embedded Apple Development-signed Release archive passed strict signature validation and was installed on an Apple Watch Series 8 running watchOS 26.5 through Xcode's paired network connection, 2026-07-20; standalone unsigned Release also passed, and final launch/matrix plus App Store distribution export remain pending |
| ESP32 1.75 firmware SHA | Pending final candidate flash |
| ESP32 2.06 firmware SHA | Pending final candidate flash |

Record dates, OS versions, device models, firmware environment, and evidence
links or filenames with each executed run. Never copy results from a different
build into the final-candidate column.

## Automated and packaging gates

| Gate | Status | Evidence |
| --- | --- | --- |
| iOS 15 compatibility/typecheck | Passed | `./scripts/run-workout-contract-tests.sh` and navigation helper suite on the post-main candidate, 2026-07-20 |
| iOS workout unit tests | Passed | 36 tests, zero failures/skips, iPhone 17 Pro Simulator from candidate `40b8e034`, 2026-07-20 |
| watchOS workout unit tests | Passed | 92 tests, zero failures/skips, Series 11 Simulator from candidate `40b8e034`, 2026-07-20 |
| iOS device and Simulator builds with embedded Watch app | Passed | Fresh unsigned Release containers in `/tmp/open-bike-postmerge-40b8e034-device` and `/tmp/open-bike-postmerge-40b8e034-simulator`, 2026-07-20 |
| Signed Release archive integrity | Passed for development signing / pending distribution export | `/tmp/open-bike-watch-companion-0c1f6452.xcarchive`; `xcodebuild clean archive` succeeded without provisioning updates, both nested signatures passed strict verification, archive version is 2, and signing team is `4H5PK8686H`, 2026-07-20. The installed identities are development identities, so this is not an App Store distribution export. |
| `ValidateEmbeddedBinary` | Passed | Both exact-candidate Release container builds and the development-signed Release archive, 2026-07-20 |
| iPhone HealthKit entitlement | Passed in signed Release archive | Signed application identifier `4H5PK8686H.LetItRide.BikeComputer`, team `4H5PK8686H`, and `com.apple.developer.healthkit = true`, 2026-07-20 |
| Watch HealthKit entitlement | Passed in signed Release archive | Signed application identifier `4H5PK8686H.LetItRide.BikeComputer.watchkitapp`, team `4H5PK8686H`, and `com.apple.developer.healthkit = true`, 2026-07-20 |
| Watch `workout-processing` background mode | Passed | Development-signed exact-candidate embedded Release Watch `Info.plist` contains `workout-processing` and points to companion `LetItRide.BikeComputer`, 2026-07-20 |
| iPhone and Watch privacy manifests in bundles | Passed | Source manifests matched the exact-candidate unsigned containers and development-signed archive byte-for-byte; archive SHA-256 values are `5f51c506726d785bedd75dba4181b6a564dc0d0ca72de58858242ade6a24842b` (iPhone) and `521eb6ef8430773e5c010e1838fe9dd8fa5d62b7b76d1cea8d7d8daadcb144e2` (Watch), 2026-07-20 |
| Watch app icon in bundle / asset validation | Passed | Exact-candidate Watch `Assets.car` and `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName = AppIcon` verified; a mutated missing-metadata fixture is rejected, 2026-07-20 |
| In-app privacy-policy reachability | Passed automated / pending final tap | iPhone Settings and Watch start screen compile against one shared HTTPS URL; URL is present in both exact-candidate Release binaries and release-asset tests pass. Open it on the final installed build before submission. |
| App Store Connect privacy-policy URL | Pending publication authorization | Enter the same documented public URL in App Store Connect and verify it resolves after merge. |
| Production privacy retention/provider contract | Pending production check | Public policy states the 30-day artifact window, verified-deletion path, and equivalent provider protection; production configuration and provider obligations must match before submission. |
| Backend retention/privacy regressions | Passed | 206 backend tests passed (one unrelated skip) after integrating current main; the subsequent candidate changes do not touch backend code, 2026-07-20. |
| Workout protocol/vector/state/presenter host tests | Passed | Strict C++ protocol/state/presenter/GPS suites plus exact protected native channel-six dispatch, replay, and wrong-channel checks, 2026-07-20 |
| Existing navigation/BLE regression tests | Passed | `./scripts/run-navigation-tests.sh` on candidate `40b8e034`, 2026-07-20 |
| `WAVESHARE_AMOLED_175` firmware build | Passed | Exact-candidate PlatformIO Release build; RAM 40.8%, flash 88.5% (2,785,031 / 3,145,728 bytes), 2026-07-20 |
| `WAVESHARE_AMOLED_206` firmware build | Passed | Exact-candidate PlatformIO Release build; RAM 40.8%, flash 88.5% (2,784,603 / 3,145,728 bytes), 2026-07-20 |
| 1.75 and 2.06 layout/interaction host tests | Passed | Both `test_gui_layout.cpp` variants after current-main integration; the candidate changes do not touch layout code, 2026-07-20 |
| App Store iPhone screenshot export validation | Passed | Four opaque 1242x2688 PNGs plus manifest/contact sheet/source provenance/ZIP; candidate changes do not touch rendering inputs or derivatives, and generation/validation/provenance/package checks passed, 2026-07-20 |
| App Store Watch screenshot dimensions/alpha | Passed | Opaque 416x496 JPEG; `bun run validate:watch`, candidate changes do not touch the asset, 2026-07-20 |

## Physical-device matrix

| # | Scenario and required observation | Final-candidate status | Evidence |
| --- | --- | --- | --- |
| 1 | Start on Watch with iPhone foreground and ESP32 connected; one coherent session appears on all three. | Pending | — |
| 2 | Start on iPhone; Watch wakes, requires the explicit start confirmation, and owns the workout. | Pending | — |
| 3 | Start without ESP32, connect it mid-workout, and receive the latest coherent state. | Pending | — |
| 4 | Disconnect and reconnect ESP32; Watch continues and ESP32 resynchronizes without stale replay. | Pending | — |
| 5 | Disable and restore Watch/iPhone Bluetooth; Watch continues and iPhone reconciles current state. | Pending | — |
| 6 | Lock/background iPhone while navigating; record end-to-end sample latency and p95. | Pending | — |
| 7 | Background iPhone without navigation; ESP32 must become honestly stale rather than show old speed as current. | Pending | — |
| 8 | Pause and resume from both Watch and iPhone; state agrees and paused time/distance do not inflate. | Pending | — |
| 9 | End and save once from Watch and once from iPhone in separate runs; each produces one synchronized terminal outcome. | Pending | — |
| 10 | With Apple's Workout active, test both BikeComputer start surfaces: warning shown, Cancel is a no-op, Start Anyway proceeds only after confirmation and reports any displacement honestly. | Pending | — |
| 11 | Deny Health access, then deny Watch location separately; workout setup and unavailable route/GPS metrics remain honest. | Pending | — |
| 12 | Ride without external sensors; optional power/cadence stay unavailable and GPS fallback behavior is correct. | Pending | — |
| 13 | Ride with cycling speed, power, and cadence sensors; available values propagate without double counting. | Pending | — |
| 14 | Terminate/crash the Watch app during a workout; relaunch and recover the same session without duplicate save. | Pending | — |
| 15 | Save after outdoor movement; Health/Fitness shows exactly one workout with route, distance, energy, and available zone data. | Pending | — |
| 16 | Run at least two hours; record Watch, iPhone, and ESP32 battery deltas plus thermal observations. | Pending | — |
| 17 | Validate readable, unclipped live/stale/paused/ended/idle screens on physical 1.75- and 2.06-inch devices. | Pending | — |

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
- heart rate and available zone information present;
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
