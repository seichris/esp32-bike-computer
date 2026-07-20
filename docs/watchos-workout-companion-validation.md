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
| Candidate commit | Pending Phase 6 checkpoint |
| iPhone build | Pending final candidate install |
| Watch build | Pending final candidate install |
| ESP32 1.75 firmware SHA | Pending final candidate flash |
| ESP32 2.06 firmware SHA | Pending final candidate flash |

Record dates, OS versions, device models, firmware environment, and evidence
links or filenames with each executed run. Never copy results from a different
build into the final-candidate column.

## Automated and packaging gates

| Gate | Status | Evidence |
| --- | --- | --- |
| iOS 15 compatibility/typecheck | Passed | `./scripts/run-workout-contract-tests.sh` and navigation helper suite, 2026-07-19 |
| iOS workout unit tests | Passed | 36 tests, zero failures/skips, iOS Simulator after privacy-link fix, 2026-07-19 |
| watchOS workout unit tests | Passed | 92 tests, zero failures/skips, Series 11 Simulator after privacy-link fix, 2026-07-19 |
| iOS device and Simulator builds with embedded Watch app | Passed | Fresh unsigned Release containers in `/tmp/open-bike-phase6-postfix-device-20260719` and `/tmp/open-bike-phase6-postfix-simulator-20260719`, 2026-07-19 |
| `ValidateEmbeddedBinary` | Passed | Both post-fix Release container builds, 2026-07-19 |
| iPhone HealthKit entitlement | Pending final signed archive inspection | Source entitlement and automated contract pass; unsigned Release build cannot prove the signed artifact |
| Watch HealthKit entitlement | Pending final signed archive inspection | Source entitlement and automated contract pass; unsigned Release build cannot prove the signed artifact |
| Watch `workout-processing` background mode | Passed | Embedded Release Watch `Info.plist` contains `workout-processing`, 2026-07-19 |
| iPhone and Watch privacy manifests in bundles | Passed | Post-fix source manifests matched the embedded Release device and Simulator bundles byte-for-byte; iPhone has all four declared collection types and Watch has none, 2026-07-19 |
| Watch app icon in bundle / asset validation | Passed | Watch `Assets.car` and `CFBundleIcons.CFBundlePrimaryIcon` present in Release bundle, 2026-07-19 |
| In-app privacy-policy reachability | Passed automated / pending final tap | iPhone Settings and Watch start screen compile against one shared HTTPS URL; URL is present in both fresh Release binaries and four release-asset tests pass. Open it on the final installed build before submission. |
| App Store Connect privacy-policy URL | Pending publication authorization | Enter the same documented public URL in App Store Connect and verify it resolves after merge. |
| Production privacy retention/provider contract | Pending production check | Public policy states the 30-day artifact window, verified-deletion path, and equivalent provider protection; production configuration and provider obligations must match before submission. |
| Backend retention/privacy regressions | Passed | 206 backend tests passed (one unrelated skip), including immutable ready-time expiry, valid-job continuation plus fail-closed destructive cleanup for unreadable records, single-scan atomic work-directory tombstoning outside the global lock, aggregate legacy/object/unexpected-GC deletion failures, exact expiry/object/work-directory partial-progress counts, allowlisted diagnostics that never include arbitrary exception text, failure-isolated idle rate-limit-pseudonym cleanup, and unhealthy maintenance signaling, 2026-07-19. |
| Workout protocol/vector/state/presenter host tests | Passed | Strict C++ protocol and state/presenter/GPS suites, 2026-07-19 |
| Existing navigation/BLE regression tests | Passed | `./scripts/run-navigation-tests.sh`, 2026-07-19 |
| `WAVESHARE_AMOLED_175` firmware build | Passed | PlatformIO Release build; RAM 40.7%, flash 87.6%, 2026-07-19 |
| `WAVESHARE_AMOLED_206` firmware build | Passed | PlatformIO Release build, 2026-07-19 |
| 1.75 and 2.06 layout/interaction host tests | Passed | Both `test_gui_layout.cpp` variants, 2026-07-19 |
| App Store iPhone screenshot export validation | Passed | Four opaque 1242x2688 PNGs plus manifest/contact sheet/source provenance/ZIP; CI recomputes every rendering-input hash and byte-compares every committed derivative with its ZIP entry, 2026-07-19 |
| App Store Watch screenshot dimensions/alpha | Passed | Opaque 416x496 JPEG; `bun run validate:watch`, 2026-07-19 |

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
