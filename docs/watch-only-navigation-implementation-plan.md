# Issue #106: Watch-only navigation implementation plan

Issue: [#106, iPhone-free rides with Watch-only navigation](https://github.com/seichris/open-bike-computer/issues/106)

Prepared from `origin/main` at `425c577044a22753335477a75508e53c7febe469`
with Xcode 26.6 and the watchOS 26.5 SDK. The project continues to target
watchOS 10 and iOS 15; iPhone workout-session mirroring remains guarded to
iOS 17 or later.

## Outcome

Let a previously enrolled Apple Watch run a complete ride while the iPhone is
off or out of range. The Watch remains the only owner and saver of the
HealthKit workout, obtains GPS, calculates and follows a cycling route, and
streams the current workout, position, route geometry, and maneuver directly
to the bike computer over authenticated BLE.

The intended direct flow is:

```text
Watch favorite + Start Ride
             |
             +--> Watch HKWorkoutSession ------------------+
             |                                              |
             +--> Watch GPS --> Watch navigation ----------+--> Watch BLE
                                                            |       |
                                                            |       v
                                                            +--> Bike computer

When the iPhone is present and already controls the bike computer:

Watch HKWorkoutSession --> mirrored workout --> iPhone BLE --> Bike computer
```

The existing iPhone-relay path remains supported. Direct Watch mode is another
transport for the same device contracts, not a second workout implementation.

## How the Watch-to-device flow starts

Yes: the normal experience should be automatic from **Start Ride**. The rider
does not choose `iPhone relay` versus `Watch direct` on every ride.

However, `WCSession.isReachable == false` must not by itself mean “the iPhone
is absent.” WatchConnectivity reachability is transient, can be false while the
iPhone still has an active BLE connection, and cannot prevent two controllers
from writing conflicting state. The safe rule is:

> Start Ride begins the Watch workout immediately, then Auto mode uses the
> iPhone relay if it is confirmed ready; otherwise the Watch scans for its
> enrolled bike computer, authenticates with its own scoped credential, and
> uses direct mode only after the bike computer grants the Watch the exclusive
> control lease.

### One-tap launch sequence

1. The rider optionally selects a synced favorite on the Watch. Selection may
   pre-calculate the cycling route while the start screen is foregrounded.
2. The rider presses **Start Ride**.
3. `WatchWorkoutManager` starts or recovers the Watch-owned workout without
   waiting for the iPhone or bike computer. A device connection failure must
   never lose the workout.
4. If a favorite was selected, Watch navigation starts as soon as the route is
   ready. If route calculation is still running, the workout continues while
   the Watch shows `Calculating route...`.
5. `WatchRideTransportArbiter` asks the iPhone for a fresh relay status with a
   short bounded deadline. A fresh `relayReady` reply for the same DeviceID
   selects `throughPhone`.
6. If there is no fresh relay-ready reply, `WatchDeviceLink` scans for the
   enrolled DeviceID, connects, authenticates its Watch controller credential,
   negotiates the direct-Watch capability, and requests the device control
   lease.
7. A granted lease selects `directWatch`. The Watch sends a full current-state
   resynchronization before starting incremental updates.
8. A busy lease, incompatible firmware, missing credential, powered-off
   Bluetooth, or connection timeout selects `workoutOnly` for now. The Watch
   shows `Ride recording - Bike Computer not connected` and retries with
   bounded backoff. It does not show a pre-ride confirmation sheet.

The mode remains sticky while healthy. The iPhone returning must not steal a
healthy Watch lease or make the route bounce between controllers. If the
current transport fails, the device lease and a monotonically increasing ride
transport generation decide the next controller; WatchConnectivity state is
advisory only.

### Start-screen experience

The ready screen should contain:

- an optional **Destination** row showing `None` or the selected favorite;
- a small **Bike Computer** status showing `Auto`, `Via iPhone`, `Direct`,
  `Not set up`, or `Unavailable`;
- the existing **Start Ride** action.

Auto remains the default. A diagnostic override can live in Developer Settings,
but production correctness must not depend on it. Selecting no destination
starts a workout and still sends direct workout metrics when possible. Starting
navigation must also remain possible during an active workout, and stopping
navigation must not end the workout.

## Product and ownership contract

| State | Authoritative owner |
| --- | --- |
| HealthKit workout, sensor metrics, pause/resume/end/save | Apple Watch |
| Favorite catalog in version 1 | iPhone, with a durable read-only Watch copy |
| Active Watch-calculated route | Apple Watch |
| Active iPhone-calculated route | iPhone |
| Current GPS in direct mode | Apple Watch |
| Current device writer | Controller holding the device-issued lease |
| Completed HealthKit workout | Apple Watch only; iPhone never saves a duplicate |
| App-specific completed ride summary | Watch, reconciled to iPhone by session UUID |

Additional rules:

- Workout and navigation have separate state machines. A combined Start Ride
  action may explicitly start both, but pause/end workout and stop navigation
  remain separate controls.
- A Watch-started direct ride remains direct when the iPhone returns. Automatic
  handoff happens only after transport failure; an explicit mid-ride handoff UI
  is a later enhancement.
- An iPhone-started workout keeps the existing iPhone BLE relay by default.
  The Watch still owns HealthKit, while iPhone navigation remains independent.
- Direct mode requires one-time enrollment while the iPhone, Watch, and bike
  computer are available. Missing enrollment is reported before or during a
  ride; it is never replaced with an insecure unowned BLE connection.
- No raw route or health stream is uploaded to a backend.

## Current `main` baseline and missing pieces

The existing implementation already provides:

- a standalone Watch app with `WKRunsIndependentlyOfCompanionApp`, Watch-owned
  `HKWorkoutSession`, route saving, recovery, and workout mirroring;
- a 16-byte workout telemetry contract and iPhone `WorkoutDeviceRelay`;
- authenticated ownership-v2 BLE with AES-GCM protected channels;
- iPhone MapKit cycling routes, route progress, maneuvers, rerouting, GPS, and
  sliding route geometry;
- iPhone-local coordinate-aware `SavedDestination` favorites;
- one current BLE connection and firmware Ride Stats/navigation presentation.

The Watch target currently has no MapKit navigation manager, CoreBluetooth
central, device credential, favorites catalog, direct packet writer, or ride
transport arbiter. `WatchRouteRecorder` also owns its `CLLocationManager` and
stops it when workout route recording ends, which cannot support an independent
navigation lifetime without refactoring.

The current device credential is an iPhone installation OwnerID and OwnerKey in
the iPhone Keychain. Copying that root credential to Watch would make both
controllers indistinguishable and give Watch ownership-administration rights.
Do not use that as the production design.

The capability response is currently a single `UInt8`, and bits `0...7` are all
assigned. Direct Watch support therefore needs a backward-compatible extended
capability response rather than silently reusing a bit.

The installed SDK confirms that watchOS exposes `MKDirections`, cycling
transport (watchOS 7+), `CBCentralManager`, and
`CLBackgroundActivitySession` (watchOS 10+). Real-device behavior while the
display is down remains an implementation gate; SDK availability alone does
not prove sustained BLE throughput or acceptable battery use.

## Target architecture

### New shared contracts

Add a `RideShared` source group with target membership in iOS, watchOS, and
host tests:

```text
ios-app/BikeComputer/RideShared/
  SavedDestinationContract.swift
  WatchSyncContract.swift
  RideTransportContract.swift
  NavigationRouteContract.swift
  NavigationRuntime.swift
  DeviceRideProtocol.swift
  DeviceTelemetryContract.swift
```

Move only platform-neutral models and algorithms into this group:

- `SavedDestinationV1` with UUID, label, latitude, and longitude;
- favorite catalog, application-context, transport status, active ride, and
  completed ride envelopes;
- route coordinates, steps, maneuvers, progress, and archive validation;
- packet builders already shared logically by iPhone and firmware;
- workout frame builders/scheduling currently embedded in
  `WorkoutDeviceRelay.swift`.

Keep MapKit request creation, CoreBluetooth delegates, Keychain access,
HealthKit, and SwiftUI in their platform targets. iPhone behavior must retain
the existing tests while its navigation engine adopts the shared route runtime.

### One WatchConnectivity owner per process

`WCSession.default.delegate` is a singleton. Today
`WorkoutWatchAvailabilityMonitor` owns it on iPhone and
`WatchHeartRateZoneSettingsReceiver` owns it on Watch. Adding more independent
delegates would cause features to replace each other.

Introduce:

- `PhoneWatchSyncCoordinator` in the iPhone target;
- `WatchSyncCoordinator` in the Watch target.

Each is the only `WCSessionDelegate` in its process and routes typed events to
workout availability, maximum-HR settings, favorites, device enrollment,
transport arbitration, and ride reconciliation.

Use each WatchConnectivity channel deliberately:

| Channel | Data |
| --- | --- |
| `applicationContext` | Latest non-secret settings, favorite catalog, active DeviceID metadata, and current ride/transport summary |
| `sendMessage` / `sendMessageData` | Fresh relay query/reply, explicit enrollment while both apps are reachable, and low-latency handoff signals |
| `transferUserInfo` | Durable completed-ride summaries and revocation receipts |
| HealthKit workout mirroring | Existing live workout snapshots and controls |

Store all non-secret latest state under one versioned top-level context. Every
update performs a read-modify-write of that envelope so synchronizing favorites
cannot erase maximum heart rate, and vice versa. Never put the Watch controller
secret in `applicationContext` or logs.

## Secure Watch controller enrollment

### Credential model

Keep the iPhone OwnerID/OwnerKey as the administrative root. Add one scoped
Watch ride controller per owned device:

```text
WatchControllerCredentialV1
  deviceID: 16 bytes
  controllerID: 16 random bytes
  controllerKey: 32 random bytes
  role: watchRide
  createdAt
  schemaVersion
```

The controller key is independent of the OwnerKey. Watch stores it in a
non-synchronizing, this-device-only Keychain item. UserDefaults contains only
the display name, DeviceID, enrollment state, and last successful connection.
The credential permits authenticated ride channels and lease operations, but
not rename, settings, firmware/map transfer, controller administration,
deregistration, or ownership recovery.

### Enrollment flow

Add **Enable direct Apple Watch connection** under the selected bike computer
in iPhone Settings.

1. Require the iPhone to have an authenticated owner session with the selected
   device and require the Watch app to be installed and interactively reachable.
2. iPhone generates a random ControllerID and ControllerKey and retains the
   pending secret in a this-device-only iPhone Keychain item until enrollment
   commits or is revoked.
3. iPhone sends a protected, owner-only `STAGE_CONTROLLER` command to firmware
   with role `watchRide`. Firmware keeps the current Watch controller active
   while it atomically persists at most one provisional replacement.
4. Firmware acknowledges the staged ControllerID. A failed NVS commit leaves
   the current credential usable and creates no partial record.
5. Only after firmware acknowledgement, iPhone transfers the credential to the
   Watch with an acknowledged interactive message.
6. Watch validates lengths and DeviceID, saves the Keychain item, and returns a
   proof generated with the new key and firmware-issued enrollment challenge.
7. iPhone forwards that proof in an owner-only `COMMIT_CONTROLLER` command.
   Firmware verifies it, atomically promotes the staged controller, and only
   then removes the previous Watch controller.
8. After firmware commit acknowledgement, iPhone marks enrollment complete and
   deletes its pending Keychain item. Interrupted setup is `pending`, not
   `enabled`; retry reconciles device and Watch state before replacing anything.

The Watch scans by service UUID and advertised DeviceID suffix because a
CoreBluetooth peripheral UUID from iPhone is not a portable Watch identifier.
It verifies the full DeviceID during authentication before sending ride data.

Revoking, replacing, or deregistering a device removes the firmware controller
first and the Watch credential second, with retryable pending-revocation state.
A physical device ownership reset clears all controllers. Watch reinstall or
Watch replacement requires enrollment again.

## BLE protocol and firmware changes

Update `docs/ble-protocol.md` and the matching iOS, Watch, and ESP32 constants
in the same protocol PR.

### Extended capability negotiation

Add capability request version `7`:

```text
client -> device: "CAPS" | Version 7
device -> client: "CAPS" | FlagsLow | FlagsHigh | Enabled | SoundID | Volume
```

Versions `1...6` and their byte-for-byte responses remain unchanged. Version 7
interprets `FlagsLow | FlagsHigh << 8` as `UInt16`; bit `8` means the complete
scoped-controller authentication and exclusive-lease contract is present.
Firmware must set bit 8 only when persistence, auth, authorization checks,
lease enforcement, and notification responses are all compiled and active.

New iPhone builds request version 7 but accept legacy version 6 responses.
Watch direct mode requires bit 8 and workout telemetry bit 7. Older firmware
continues to work through iPhone relay and shows `Update Bike Computer firmware
for direct Watch connection` on Watch/iPhone setup surfaces.

### Scoped authentication

Add a bounded controller challenge beside the existing `OWNER/SERVER2/PROOF/OK2`
flow. Use domain-separated HMAC labels that include DeviceID, ControllerID, both
fresh 16-byte nonces, protocol version, and role. Derive write/notify keys from
the ControllerKey with new domain labels, while retaining the existing S2/R2
frame shape and per-channel sequence enforcement.

Firmware rejects:

- unknown, revoked, malformed, or wrong-device controllers;
- replayed nonces, proofs, sequences, or old-session frames;
- a `watchRide` controller command outside its allowed channel set;
- plaintext commands after the protected controller session opens.

Do not expose the OwnerKey, controller key, nonces, full DeviceID, or decrypted
health payloads in production logs.

### Exclusive control lease

Authentication proves identity; a lease grants write authority. Add protected
`CLAIM_CONTROL`, `CONTROL_GRANTED`, `CONTROL_BUSY`, `RENEW_CONTROL`, and
`RELEASE_CONTROL` messages on the auth channel.

The firmware lease contains:

- authenticated ControllerID or legacy owner-session identity;
- device-issued non-zero lease generation;
- ride session token when available;
- last accepted activity time;
- a short documented expiry interval.

Lease rules:

- only one controller can hold it;
- a lease is released immediately when its BLE connection closes cleanly and
  otherwise expires after its heartbeat deadline;
- valid GPS, route, maneuver, workout, and ride-control frames refresh the
  holder's lease, while an idle link sends a bounded heartbeat;
- non-holders receive `CONTROL_BUSY` and their ride-channel writes are rejected;
- reconnect creates a new authenticated session and lease generation, then
  requires a full state resynchronization;
- old iPhone clients keep working on current single-connection firmware through
  an implicit legacy owner lease; this compatibility path never authorizes a
  scoped Watch controller without bit 8.

Add firmware host tests for concurrent claims, expiry boundaries, disconnect,
replay, stale generations, authorization scopes, NVS failure, device reset, and
old iPhone compatibility.

## Watch implementation

### `WatchLocationService`

Refactor `WatchRouteRecorder` so one `WatchLocationService` owns Core Location.
The service maintains consumers for workout-route recording and navigation and
runs while either lifecycle needs it. `WatchRouteRecorder` remains responsible
only for filtering/batching locations into `HKWorkoutRouteBuilder`.

When navigation is active, hold a `CLBackgroundActivitySession` on watchOS 10+
and resume it immediately on a navigation recovery launch. Preserve the current
workout-processing mode. Do not assume an iOS-only `bluetooth-central`
background declaration is valid for the Watch target; the real-device spike
must confirm direct BLE and GPS continue while wrist-down under workout and
location background activity.

Enable the Watch target's supported background location capability required by
`CLBackgroundActivitySession`, verify the built Watch plist contains the
expected location mode, and add a Watch-specific
`NSBluetoothAlwaysUsageDescription` for the direct bike-computer connection.
Keep `WKBackgroundModes = workout-processing`; do not add an undocumented Watch
Bluetooth background value.

### `WatchFavoriteStore`

The iPhone is authoritative for version 1. Publish a monotonic catalog revision
and content hash through application context. Watch validates schema, unique
IDs, coordinates, label byte limits, count, total payload size, and revision
before atomically replacing its local copy.

- Sync up to 25 coordinate-backed favorites, bounded to 32 KiB.
- Keep the last valid catalog when iPhone is absent.
- Enrich query-only iPhone favorites with a resolved coordinate before syncing;
  unresolved favorites remain on iPhone and show a non-blocking explanation.
- Never geocode a stale free-form label on Watch and assume it is the original
  favorite.

### `WatchNavigationManager`

Use `MKDirections` with `.cycling`, Watch GPS as the source, and the selected
favorite coordinate as destination. Convert `MKRoute` immediately into a
versioned, pure-Foundation `NavigationRouteV1` containing bounded route points,
steps, instructions, distance, expected time, destination, and creation time.

Reuse the shared navigation runtime for:

- closest-step selection and route progress;
- distance and instruction updates;
- instruction-to-icon mapping;
- route-deviation detection and reroute cooldown;
- the same 30-point sliding device-geometry window and coordinate conversion
  used by iPhone;
- full navigation resynchronization after device reconnect.

Persist one active `NavigationRouteArchiveV1` atomically with file protection,
checksum, schema version, maximum point/step counts, and maximum encoded size.
The archive contains no health samples. On network loss, continue along this
route and show `Offline - continuing current route`. A reroute failure retains
the existing route, announces that rerouting is unavailable, and retries only
after both connectivity recovery and the cooldown. Offline route calculation
and downloadable route packs are explicitly later work.

### `WatchDeviceLink`

Implement a small Watch-specific CoreBluetooth central rather than adding the
iPhone's large `BLEManager.swift` to the Watch target. It should:

- retrieve or scan only for the bike-computer service and enrolled identity;
- connect, discover the required characteristics, negotiate MTU, authenticate
  the scoped credential, request capabilities, and claim the lease;
- expose typed readiness and lease state to `WatchRideTransportArbiter`;
- use one bounded, priority-aware write queue with coalescing for GPS, geometry,
  maneuver, and workout frames;
- send the same authenticated native characteristics and documented fallbacks
  as iPhone;
- discard stale callbacks by connection generation;
- apply bounded exponential reconnect backoff and stop scanning when neither
  workout nor navigation needs the device;
- on readiness, send in order: active/clear workout pair, current GPS, route
  geometry, and current maneuver.

Extract `WorkoutDeviceFrames`, builders, correlation rules, and scheduler into
`DeviceTelemetryContract.swift`. Both iPhone and Watch consume the same code so
heart-rate zones, unavailable sentinels, pair generations, terminal states, and
source flags cannot drift.

### `WatchRideTransportArbiter`

Model explicit states rather than booleans:

```text
idle
resolving(generation)
throughPhone(generation, deviceID)
connectingDirect(generation, deviceID)
directWatch(generation, deviceID, leaseGeneration)
workoutOnly(generation, reason, nextRetry)
```

Inputs are active workout/navigation demand, enrolled credential, fresh iPhone
relay response, Watch Bluetooth state, direct connection state, firmware
capabilities, lease response, and monotonic transport generation. Reachability
is only a way to ask for current status.

Transitions must be deterministic and covered by table-driven tests. Delayed
iPhone replies, BLE callbacks, reconnect timers, and prior-ride state cannot
change a newer generation. `throughPhone` gates the existing iPhone relay;
`directWatch` gates Watch writes. Firmware lease enforcement remains the final
split-brain defense.

### UI and controls

Extend the Watch UI with:

- a favorites picker and route calculation status on the start screen;
- compact transport state in the live view;
- maneuver, distance, remaining route, and reroute/offline status;
- separate workout pause/resume/end and navigation stop/change actions;
- setup guidance for missing favorites, location, network, firmware, or direct
  controller enrollment;
- no `Start Ride?` confirmation for a normal launch.

Failure copy must distinguish `workout not started`, `navigation unavailable`,
and `bike computer not connected`. A route or device failure must not imply
that the Watch workout stopped.

## iPhone changes

1. Replace direct `WCSessionDelegate` ownership with
   `PhoneWatchSyncCoordinator` while preserving current Watch availability and
   maximum-HR behavior.
2. Publish coordinate-rich favorites whenever the authoritative store changes
   and resolve any query-only favorites before Watch eligibility.
3. Add controller enrollment/revocation UI and persistent pending-operation
   state to the selected device settings.
4. Extend `BLEManager` for capability version 7, owner-only controller
   administration, and explicit/implicit lease state.
5. Make `WorkoutDeviceRelay` conditional on the current ride transport. A
   mirrored Watch workout must not make iPhone write when Watch holds the direct
   lease.
6. Answer Watch relay probes with DeviceID, authentication readiness, lease
   generation, transport generation, and timestamp. Never claim `relayReady`
   solely because the iPhone app is reachable.
7. When a direct Watch ride later appears, remain an observer while direct mode
   is healthy. Display the mirrored workout and synced ride/navigation summary,
   but do not auto-steal the BLE connection.
8. Reconcile durable completed-ride messages by Watch workout session UUID.
   HealthKit synchronization supplies the workout; the message supplies only
   app state such as destination, navigation outcome, and transport history.

## Recovery and lifecycle behavior

| Event | Required behavior |
| --- | --- |
| iPhone is off before Start Ride | Watch starts workout, calculates route if requested, authenticates directly, claims lease, and streams full state. |
| iPhone reply times out but still owns BLE | Watch cannot acquire the device/lease, records the workout, reports device unavailable, and retries; it never sends unauthenticated data. |
| iPhone returns during healthy direct ride | Watch keeps lease; iPhone observes and reconciles. |
| Direct BLE drops | Workout and navigation continue; Watch reconnects with a new session/lease and full resync. A freshly ready iPhone relay may take over only after the old lease is gone. |
| Bike computer reboots | Watch reauthenticates, reclaims, and sends workout, GPS, geometry, then maneuver. |
| Network drops after route load | Continue cached route; suppress destructive reroute replacement. |
| Network is absent before route load | Start workout if requested, show route calculation failure, and allow retry or workout-only riding. |
| Watch app is relaunched | Recover workout and navigation independently, resume needed location activity, then resolve transport from a new generation. |
| Workout pauses | Keep navigation and lease alive; send paused workout state. |
| Workout ends while navigation continues | Save exactly one workout, clear workout telemetry, keep location/navigation/device link active. |
| Navigation stops while workout continues | Clear route geometry/instruction, keep direct workout telemetry active. |
| Both lifecycles end | Send clear frames, release lease, stop BLE/location work, persist completed ride summary. |
| Watch credential is revoked | Delete it locally after receipt; current or later controller auth fails closed. |

## Delivery phases

### Phase 0: real-device feasibility and protocol proof

1. Build a throwaway Watch-target spike that calculates a cycling route and
   connects to the service while a BikeComputer workout is active.
2. On physical Watch, validate foreground, wrist-down, Always On display,
   background workout, pause, and location-background cases for at least a
   representative long ride window.
3. Measure GPS cadence, BLE write stability, reconnect behavior, Watch battery
   delta versus the current workout-only build, and ESP32 power impact.
4. Prototype capability-v7 parsing and controller/lease host tests before
   changing production ownership storage.

Gate: do not proceed to full UI until cycling directions and sustained direct
BLE/GPS are proven on the minimum supported watchOS hardware. If navigation
without an active workout cannot keep the process alive reliably, keep the
state machines independent but document active-workout background execution as
the first-release requirement and open a follow-up for standalone navigation.

### Phase 1: shared contracts and WatchConnectivity router

1. Add `RideShared` models, validation, and host tests.
2. Centralize WCSession ownership on iPhone and Watch.
3. Migrate maximum-HR sync without behavior changes.
4. Add favorites application-context sync and durable Watch storage.

Gate: existing workout tests remain green; changing favorites and max HR in
either order preserves both latest values; Watch favorites work with iPhone
powered off after a successful prior sync.

### Phase 2: firmware controller authentication and lease

1. Add atomic scoped-controller NVS state and owner-only add/remove commands.
2. Add controller handshake, authorization scopes, lease state, and expiry.
3. Add capability-v7 `UInt16` response while preserving v1-v6 bytes.
4. Extend iPhone ownership code and enrollment UI.
5. Add shared crypto test vectors to
   `docs/device-ownership-test-vectors.json`.

Gate: firmware host tests cover success, failure, replay, scope, power-loss,
lease races, and legacy clients on every firmware target; a physical ownership
reset remains recoverable.

### Phase 3: direct Watch telemetry

1. Add Watch Keychain credential store and enrollment receipt.
2. Implement `WatchDeviceLink`, write queue, auth, capability, and lease.
3. Extract and reuse workout telemetry builders.
4. Implement the transport arbiter and gate iPhone/Watch writers.
5. Add direct mode status and setup errors without navigation yet.

Gate: with iPhone off, Watch Start Ride shows current workout metrics on Ride
Stats; reconnect and device reboot resynchronize; an adversarial dual-controller
test never accepts both writers.

### Phase 4: Watch routing and navigation

1. Refactor Watch location ownership.
2. Add MapKit cycling route calculation from synced favorites.
3. Add shared route runtime, route archive, maneuver and geometry output.
4. Add rerouting with cooldown and offline continuation.
5. Add live navigation UI and independent navigation controls.

Gate: with iPhone off, a favorite route produces accurate GPS, geometry,
maneuvers, progress, and reroute behavior on the Watch and bike computer, and a
loaded route continues after network loss.

### Phase 5: recovery, reconciliation, and release hardening

1. Recover workout, navigation, location activity, and transport independently.
2. Add completed ride transfer/reconciliation without iPhone HealthKit writes.
3. Complete revocation, Watch replacement, upgrade, downgrade, and older
   firmware behavior.
4. Update README, `ios-app/README.md`, privacy disclosures if required,
   release notes, and `docs/ble-protocol.md`.
5. Run the physical validation matrix and attach evidence to issue #106 or a
   dedicated validation issue before release.

Gate: all automated and physical acceptance criteria below pass, with measured
battery and connectivity results recorded.

## Automated verification

### Shared/iOS/watchOS tests

- automatic transport table: fresh phone relay, stale reply, unreachable phone,
  direct grant, busy lease, missing credential, old firmware, delayed callback,
  reconnect, and sticky healthy mode;
- application-context merge, revision, malformed/oversized catalog, query-only
  favorite, and downgrade behavior;
- controller Keychain validation, interrupted enrollment, replacement, and
  revocation reconciliation;
- route archive validation/corruption, route progress, maneuver transitions,
  geometry parity, deviation, reroute cooldown, and network-loss retention;
- direct and iPhone telemetry frame parity for all states, unavailable values,
  HR zone, pair generation, and source flags;
- independent workout/navigation lifecycle transitions and recovery;
- completed ride deduplication by session UUID and no iPhone workout save path.

Extend `ios-app/scripts/run-navigation-tests.sh`, the workout contract scripts,
and the Watch target tests so CI compiles all shared contracts for macOS host,
iOS, and watchOS. Keep the Release Watch build and iOS app-container build as
required CI jobs.

### Firmware host tests

- CAPS versions 1-6 unchanged and version 7 two-byte flags;
- scoped authentication success and all malformed/HMAC/replay failures;
- command authorization by controller role;
- lease grant, busy, renew, explicit release, disconnect, timeout, wraparound,
  stale generation, and simultaneous claim ordering;
- Watch and iPhone full-state resynchronization after reboot;
- workout/GPS/geometry/maneuver writes rejected from non-holder;
- legacy owner client and firmware fallback compatibility;
- atomic NVS commit failure and physical reset.

## Physical validation matrix

Use a real paired iPhone, Apple Watch, and each supported Waveshare firmware
target. Simulator-only results are insufficient.

1. Enroll Watch, sync multiple coordinate favorites, power iPhone off, select a
   favorite, press Start Ride, and complete a routed ride.
2. Repeat with iPhone out of BLE range but still paired.
3. Confirm direct mode also carries a workout-only ride with no destination.
4. Pause/resume/end workout while navigation remains active; then stop
   navigation separately. Repeat in the opposite order.
5. Lock/lower the Watch display for an extended ride and verify GPS, maneuvers,
   workout frames, lease heartbeats, and reconnects continue.
6. Drop network after route load; then test no network before route calculation.
7. Deviate from route, lose network during reroute, recover network, and verify
   the current route is never erased by a failed reroute.
8. Power-cycle the bike computer mid-ride and verify ordered full resync.
9. Bring iPhone back during direct mode and verify there is one device writer.
10. Start from iPhone and verify the existing relay path and iPhone navigation
    remain unchanged.
11. Test old firmware, current firmware, new firmware with old iPhone app, and
    app downgrade after enrollment.
12. Revoke the Watch, replace/reinstall the Watch app, deregister the device,
    and perform physical ownership reset.
13. Kill/relaunch Watch app during workout, during navigation, during both, and
    during end/save reconciliation.
14. Confirm Health contains exactly one cycling workout for every saved ride
    and none for discard, with one route when location data is valid.
15. Record Watch battery drain against the current workout-only baseline and
    retain the measurement with release evidence; investigate any material
    regression before release.

## Acceptance criteria

- A previously enrolled rider can turn the iPhone off, choose a synced favorite
  on Watch, press Start Ride once, and receive live workout, GPS, route geometry,
  and maneuvers on the bike computer.
- Mode selection is automatic, but direct writes begin only after authenticated
  Watch controller proof and device-issued exclusive lease.
- A false/stale WatchConnectivity reachability signal cannot create two accepted
  device writers.
- The Watch workout starts and saves even when route calculation or direct BLE
  fails.
- Loaded navigation continues when network disappears; failed rerouting does
  not destroy the current route.
- Workout and navigation can pause/stop/end independently, and their recovery
  state does not overwrite the other lifecycle.
- Direct reconnect and device reboot restore a coherent full state without
  stale route, workout, or controller-generation data.
- The returning iPhone observes a direct ride without stealing it and later
  reconciles app ride state by session UUID.
- Exactly one HealthKit workout is saved by Watch; iPhone never creates a second
  workout for the same ride.
- Existing iPhone relay, navigation, older-firmware fallback, ownership reset,
  and all CI targets remain functional.

## Explicit non-goals for the first release

- Watch-side free-text search or editing the authoritative favorite list;
- downloadable offline routing packs or offline route calculation;
- automatic mid-ride preference switching merely to optimize battery;
- giving Watch firmware-update, map-transfer, rename, deregister, or ownership
  administration privileges;
- attaching to a workout owned by Apple Workout or another app;
- cloud storage of raw GPS or HealthKit samples.
