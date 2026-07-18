import CoreLocation
import HealthKit
import XCTest

@MainActor
final class WatchWorkoutManagerTests: XCTestCase {
    func testAuthorizationPoliciesFailClosedWithoutInventingPermission() {
        XCTAssertEqual(
            WatchWorkoutManager.resolveSetupState(
                shareStatuses: [.sharingDenied, .notDetermined],
                requestStatus: nil
            ),
            .denied
        )
        XCTAssertEqual(
            WatchWorkoutManager.resolveSetupState(
                shareStatuses: [.sharingAuthorized, .sharingAuthorized],
                requestStatus: nil
            ),
            .ready
        )
        XCTAssertEqual(
            WatchWorkoutManager.resolveSetupState(
                shareStatuses: [.sharingAuthorized, .sharingAuthorized],
                requestStatus: .shouldRequest
            ),
            .needsAuthorization
        )
        XCTAssertEqual(
            WatchWorkoutManager.resolveSetupState(
                shareStatuses: [.sharingAuthorized, .sharingAuthorized],
                requestStatus: .unnecessary
            ),
            .ready
        )
        XCTAssertNil(
            WatchWorkoutManager.resolveSetupState(
                shareStatuses: [.notDetermined],
                requestStatus: nil
            )
        )
        XCTAssertEqual(
            WatchWorkoutManager.resolveSetupState(
                shareStatuses: [.notDetermined],
                requestStatus: .shouldRequest
            ),
            .needsAuthorization
        )
        XCTAssertEqual(
            WatchWorkoutManager.resolveSetupState(
                shareStatuses: [.notDetermined],
                requestStatus: .unnecessary
            ),
            .ready
        )

        XCTAssertEqual(WatchRouteRecorder.mapAuthorization(.denied), .denied)
        XCTAssertEqual(WatchRouteRecorder.mapAuthorization(.restricted), .denied)
        XCTAssertEqual(WatchRouteRecorder.mapAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(WatchRouteRecorder.mapAuthorization(.authorizedWhenInUse), .authorized)
    }

    func testWorkoutIdentityMetadataUsesStableHealthKitIdentifiers() {
        let sessionID = UUID(uuidString: "769C5984-D589-4CB9-88A5-A97559D5A5DB")!
        let metadata = WatchWorkoutManager.workoutIdentityMetadata(
            sessionID: sessionID
        )

        XCTAssertEqual(
            metadata[HKMetadataKeyExternalUUID] as? String,
            sessionID.uuidString
        )
        XCTAssertEqual(
            metadata[HKMetadataKeySyncIdentifier] as? String,
            "LetItRide.BikeComputer.workout.\(sessionID.uuidString)"
        )
        XCTAssertEqual(metadata[HKMetadataKeySyncVersion] as? Int, 1)
        XCTAssertTrue(
            WatchWorkoutManager.hasWorkoutIdentityMetadata(
                metadata,
                sessionID: sessionID
            )
        )

        var incomplete = metadata
        incomplete.removeValue(forKey: HKMetadataKeySyncVersion)
        XCTAssertFalse(
            WatchWorkoutManager.hasWorkoutIdentityMetadata(
                incomplete,
                sessionID: sessionID
            )
        )
        XCTAssertNil(
            WatchWorkoutManager.workoutIdentitySessionID(from: incomplete)
        )
        XCTAssertTrue(
            WatchWorkoutManager.containsWorkoutIdentityMetadata(incomplete)
        )
        XCTAssertEqual(
            WatchWorkoutManager.workoutIdentitySessionID(from: metadata),
            sessionID
        )
        XCTAssertFalse(
            WatchWorkoutManager.containsWorkoutIdentityMetadata([:])
        )
    }

    func testRecoveredIdentityAdoptsOnlyValidatedHealthKitUUID() throws {
        let persistence = ToggleRecoveryPersistence()
        let store = WatchWorkoutRecoveryStore(persistence: persistence)
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_500)
        let stableSessionID = UUID()

        XCTAssertEqual(store.loadState, .missing)
        XCTAssertThrowsError(
            try store.useRecoveredIdentity(startDate: startDate)
        )
        XCTAssertNil(store.recoveredIdentity)

        let adopted = try store.useRecoveredIdentity(
            startDate: startDate,
            stableSessionID: stableSessionID
        )
        XCTAssertEqual(adopted.sessionID, stableSessionID)
        XCTAssertNotEqual(adopted.sessionToken, 0)
        XCTAssertEqual(
            WatchWorkoutRecoveryStore(persistence: persistence)
                .recoveredIdentity?.sessionID,
            stableSessionID
        )

        XCTAssertThrowsError(
            try store.useRecoveredIdentity(
                startDate: startDate,
                stableSessionID: UUID()
            )
        )
        XCTAssertEqual(store.recoveredIdentity?.sessionID, stableSessionID)
    }

    func testCorruptOrUnavailableRecoveryLoadCannotBeClearedOrOverwritten() async throws {
        let persistence = ToggleRecoveryPersistence()
        persistence.data = Data([0x00, 0x01, 0x02])
        let store = WatchWorkoutRecoveryStore(persistence: persistence)
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_600)

        XCTAssertEqual(store.loadState, .corrupt)
        XCTAssertNil(store.recoveredIdentity)
        XCTAssertThrowsError(
            try store.useRecoveredIdentity(startDate: startDate)
        )

        let stableSessionID = UUID()
        XCTAssertThrowsError(
            try store.useRecoveredIdentity(
                startDate: startDate,
                stableSessionID: stableSessionID
            )
        )
        XCTAssertNil(store.recoveredIdentity)
        XCTAssertEqual(persistence.data, Data([0x00, 0x01, 0x02]))
        XCTAssertThrowsError(try store.clear())
        XCTAssertThrowsError(try store.begin(startDate: startDate))
        XCTAssertEqual(persistence.data, Data([0x00, 0x01, 0x02]))

        let recovery = RecoveryProbe()
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: store,
            recoverActiveWorkoutSession: { await recovery.run() },
            initializeOnLaunch: false
        )
        manager.retrySetup()
        try await waitUntil { manager.setupState == .failed }
        XCTAssertEqual(recovery.callCount, 0)
        XCTAssertEqual(persistence.data, Data([0x00, 0x01, 0x02]))
        XCTAssertTrue(manager.hasCorruptRecoveryState)

        persistence.failsQuarantine = true
        manager.confirmResetCorruptRecovery()
        XCTAssertEqual(store.loadState, .corrupt)
        XCTAssertEqual(persistence.data, Data([0x00, 0x01, 0x02]))
        XCTAssertTrue(persistence.quarantinedData.isEmpty)

        persistence.failsQuarantine = false
        manager.confirmResetCorruptRecovery()
        try await waitUntil { recovery.callCount == 1 }
        XCTAssertEqual(store.loadState, .valid)
        XCTAssertTrue(store.hasCorruptResetAuthorization)
        XCTAssertNotEqual(persistence.data, Data([0x00, 0x01, 0x02]))
        XCTAssertEqual(
            persistence.quarantinedData,
            [Data([0x00, 0x01, 0x02])],
            "confirmed recovery must preserve the exact corrupt bytes before replacement"
        )
        XCTAssertFalse(manager.hasCorruptRecoveryState)
        recovery.completeWithError()
        try await waitUntil { manager.setupState == .failed && !manager.isRecovering }
        XCTAssertTrue(
            store.hasCorruptResetAuthorization,
            "failed system recovery must retain rider-approved terminal cleanup authority"
        )

        let unavailablePersistence = ToggleRecoveryPersistence()
        let originalStore = WatchWorkoutRecoveryStore(
            persistence: unavailablePersistence
        )
        let originalIdentity = try originalStore.begin(startDate: startDate)
        let originalBytes = try XCTUnwrap(unavailablePersistence.data)
        unavailablePersistence.failsLoad = true
        let unavailableStore = WatchWorkoutRecoveryStore(
            persistence: unavailablePersistence
        )
        XCTAssertEqual(unavailableStore.loadState, .unavailable)
        XCTAssertThrowsError(
            try unavailableStore.useRecoveredIdentity(
                startDate: startDate,
                stableSessionID: stableSessionID
            )
        )
        XCTAssertNil(unavailableStore.recoveredIdentity)
        XCTAssertThrowsError(try unavailableStore.clear())
        XCTAssertThrowsError(try unavailableStore.begin(startDate: startDate))
        XCTAssertEqual(unavailablePersistence.data, originalBytes)

        let unavailableRecovery = RecoveryProbe()
        let unavailableManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: unavailableStore,
            recoverActiveWorkoutSession: { await unavailableRecovery.run() },
            initializeOnLaunch: false
        )
        unavailableManager.retrySetup()
        try await waitUntil { unavailableManager.setupState == .failed }
        XCTAssertTrue(unavailableManager.hasUnavailableRecoveryState)
        XCTAssertEqual(unavailableRecovery.callCount, 0)
        XCTAssertEqual(unavailablePersistence.data, originalBytes)

        unavailablePersistence.failsLoad = false
        unavailableManager.retrySetup()
        try await waitUntil { unavailableRecovery.callCount == 1 }
        XCTAssertEqual(unavailableStore.loadState, .valid)
        XCTAssertEqual(
            unavailableStore.recoveredIdentity?.sessionID,
            originalIdentity.sessionID
        )
        XCTAssertEqual(unavailablePersistence.data, originalBytes)
        unavailableRecovery.completeWithError()
        try await waitUntil {
            unavailableManager.setupState == .failed
                && !unavailableManager.isRecovering
        }
        XCTAssertEqual(
            unavailableStore.recoveredIdentity?.sessionID,
            originalIdentity.sessionID,
            "production retry must reload and retain the original durable identity"
        )
        XCTAssertEqual(unavailablePersistence.data, originalBytes)
    }

    func testFileRecoveryQuarantinePreservesBytesAndReplacesActiveWithAuthorization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(
            "active-watch-workout-v1.plist"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let corruptBytes = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        try corruptBytes.write(to: fileURL)

        let store = WatchWorkoutRecoveryStore(
            persistence: WorkoutRecoveryFilePersistence(fileURL: fileURL)
        )
        XCTAssertEqual(store.loadState, .corrupt)
        try store.quarantineCorruptState()

        XCTAssertEqual(store.loadState, .valid)
        XCTAssertTrue(store.hasCorruptResetAuthorization)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let directoryURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(directoryURLs.count, 2)
        let quarantineURL = try XCTUnwrap(
            directoryURLs.first { $0 != fileURL }
        )
        XCTAssertTrue(
            quarantineURL.lastPathComponent.hasPrefix(
                "active-watch-workout-v1-corrupt-"
            )
        )
        XCTAssertEqual(try Data(contentsOf: quarantineURL), corruptBytes)
        let relaunchedStore = WatchWorkoutRecoveryStore(
            persistence: WorkoutRecoveryFilePersistence(fileURL: fileURL)
        )
        XCTAssertEqual(relaunchedStore.loadState, .valid)
        XCTAssertTrue(relaunchedStore.hasCorruptResetAuthorization)
        XCTAssertNil(relaunchedStore.recoveredIdentity)
    }

    func testCorruptResetAuthorizationAdoptsTerminalSessionAsDiscardOnly() async throws {
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_650)
        let endDate = startDate.addingTimeInterval(90)

        for terminalState in [HKWorkoutSessionState.stopped, .ended] {
            let persistence = ToggleRecoveryPersistence()
            persistence.data = Data([0x00, 0x01, 0x02])
            let originalStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            try originalStore.quarantineCorruptState()

            // Relaunch proves the rider authorization is durable across the
            // exact crash window that previously left terminal recovery stuck.
            let relaunchedStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            XCTAssertTrue(relaunchedStore.hasCorruptResetAuthorization)
            let stableSessionID = UUID()
            let manager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: relaunchedStore,
                initializeOnLaunch: false
            )
            let terminalBuilder = RecoveredIdentityProbe(
                metadata: WatchWorkoutManager.workoutIdentityMetadata(
                    sessionID: stableSessionID
                ),
                sessionState: terminalState,
                endDate: endDate
            )

            let recovered = await manager.recoverWorkoutIdentity(
                using: terminalBuilder.adapter(startDate: startDate)
            )
            XCTAssertEqual(recovered?.sessionID, stableSessionID)
            XCTAssertEqual(
                recovered?.finishRequest,
                WatchWorkoutRecoveryStore.FinishRequest(
                    disposition: .discard,
                    requestedAt: endDate
                ),
                "rider-approved terminal recovery must be discard-only"
            )
            XCTAssertFalse(relaunchedStore.hasCorruptResetAuthorization)
            let persisted = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            XCTAssertEqual(persisted.recoveredIdentity, recovered)
            XCTAssertEqual(
                persisted.recoveredIdentity?.finishRequest?.disposition,
                .discard
            )
        }

        let choicePersistence = ToggleRecoveryPersistence()
        choicePersistence.data = Data([0x00, 0x01, 0x02])
        let choiceStore = WatchWorkoutRecoveryStore(
            persistence: choicePersistence
        )
        try choiceStore.quarantineCorruptState()
        let choiceIdentity = try choiceStore.useRecoveredIdentity(
            startDate: startDate,
            stableSessionID: UUID()
        )
        XCTAssertEqual(choiceIdentity.corruptResetPendingFinishChoice, true)
        let choiceManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: choiceStore,
            initializeOnLaunch: false
        )
        XCTAssertTrue(
            choiceManager.persistFinishRequest(
                disposition: .save,
                requestedAt: endDate
            )
        )
        XCTAssertEqual(choiceStore.recoveredIdentity?.finishRequest?.disposition, .save)
        XCTAssertEqual(
            choiceStore.recoveredIdentity?.corruptResetPendingFinishChoice,
            false,
            "only an explicit rider finish choice may clear corrupt-reset protection"
        )
    }

    func testCorruptResetActiveAdoptionRemainsDiscardOnlyAcrossTerminalRaceAndCrash() async throws {
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_675)
        let endDate = startDate.addingTimeInterval(75)

        for terminalState in [HKWorkoutSessionState.stopped, .ended] {
            let racePersistence = ToggleRecoveryPersistence()
            racePersistence.data = Data([0x00, 0x01, 0x02])
            let corruptStore = WatchWorkoutRecoveryStore(
                persistence: racePersistence
            )
            try corruptStore.quarantineCorruptState()
            let raceStore = WatchWorkoutRecoveryStore(
                persistence: racePersistence
            )
            let stableSessionID = UUID()
            let raceManager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: raceStore,
                initializeOnLaunch: false
            )
            var stateReadCount = 0
            let racedIdentity = await raceManager.recoverWorkoutIdentity(
                using: WatchRecoveredWorkoutIdentityAdapter(
                    metadata: {
                        WatchWorkoutManager.workoutIdentityMetadata(
                            sessionID: stableSessionID
                        )
                    },
                    startDate: startDate,
                    sessionState: {
                        stateReadCount += 1
                        return stateReadCount == 1 ? .running : terminalState
                    },
                    endDate: { endDate },
                    attachMetadata: { _ in }
                )
            )
            XCTAssertGreaterThanOrEqual(stateReadCount, 2)
            XCTAssertEqual(racedIdentity?.sessionID, stableSessionID)
            XCTAssertEqual(
                racedIdentity?.finishRequest?.disposition,
                .discard,
                "a terminal transition during corrupt-reset adoption must never default to Save"
            )
            XCTAssertEqual(
                racedIdentity?.corruptResetPendingFinishChoice,
                true,
                "automatic discard must retain the durable corrupt-reset provenance"
            )

            // Simulate the narrower crash window immediately after the active
            // identity was persisted but before the manager could re-read state.
            let crashPersistence = ToggleRecoveryPersistence()
            crashPersistence.data = Data([0x00, 0x01, 0x02])
            let resetStore = WatchWorkoutRecoveryStore(
                persistence: crashPersistence
            )
            try resetStore.quarantineCorruptState()
            let preCrashIdentity = try resetStore.useRecoveredIdentity(
                startDate: startDate,
                stableSessionID: stableSessionID
            )
            XCTAssertNil(preCrashIdentity.finishRequest)
            XCTAssertEqual(
                preCrashIdentity.corruptResetPendingFinishChoice,
                true
            )

            let postCrashStore = WatchWorkoutRecoveryStore(
                persistence: crashPersistence
            )
            let postCrashManager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: postCrashStore,
                initializeOnLaunch: false
            )
            let terminalProbe = RecoveredIdentityProbe(
                metadata: WatchWorkoutManager.workoutIdentityMetadata(
                    sessionID: stableSessionID
                ),
                sessionState: terminalState,
                endDate: endDate
            )
            let postCrashIdentity = await postCrashManager.recoverWorkoutIdentity(
                using: terminalProbe.adapter(startDate: startDate)
            )
            XCTAssertEqual(
                postCrashIdentity?.finishRequest?.disposition,
                .discard,
                "relaunch after identity persistence must resolve terminal recovery as discard-only"
            )

            let detachedStore = WatchWorkoutRecoveryStore(
                persistence: crashPersistence
            )
            let recovery = RecoveryProbe()
            var savedLookupCount = 0
            var saveFinalizationClaims: [WorkoutSaveFinalizationMode?] = []
            let detachedManager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: detachedStore,
                recoverActiveWorkoutSession: { await recovery.run() },
                savedWorkoutLookup: { _, _ in
                    savedLookupCount += 1
                    return nil
                },
                finalizationClaimObserver: {
                    saveFinalizationClaims.append($0)
                },
                initializeOnLaunch: false
            )
            detachedManager.retrySetup()
            try await waitUntil { recovery.callCount == 1 }
            recovery.completeWithoutSession()
            try await waitUntil {
                !detachedManager.isRecovering && detachedManager.state == .ending
            }
            XCTAssertEqual(savedLookupCount, 0)
            XCTAssertTrue(saveFinalizationClaims.isEmpty)
            XCTAssertNil(detachedManager.summary)
            XCTAssertEqual(
                detachedStore.recoveredIdentity?.finishRequest?.disposition,
                .discard,
                "nil recovery must retain reset-protected discard until the real session is cleaned"
            )
            XCTAssertNil(
                detachedStore.terminalTombstone(
                    externalUUID: stableSessionID.uuidString
                )
            )
        }
    }

    func testManagerRecoveredIdentityPathValidatesAdoptsAndFailsClosed() async throws {
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_700)

        for activeState in [HKWorkoutSessionState.running, .paused] {
            let stableSessionID = UUID()
            let missingStore = WatchWorkoutRecoveryStore(
                persistence: ToggleRecoveryPersistence()
            )
            let adoptingManager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: missingStore,
                initializeOnLaunch: false
            )
            let validActiveBuilder = RecoveredIdentityProbe(
                metadata: WatchWorkoutManager.workoutIdentityMetadata(
                    sessionID: stableSessionID
                ),
                sessionState: activeState
            )
            let adopted = await adoptingManager.recoverWorkoutIdentity(
                using: validActiveBuilder.adapter(startDate: startDate)
            )
            XCTAssertEqual(adopted?.sessionID, stableSessionID)
            XCTAssertEqual(validActiveBuilder.attachCallCount, 0)
            XCTAssertEqual(
                missingStore.recoveredIdentity?.sessionID,
                stableSessionID,
                "\(activeState) recovery must adopt the validated stable identity"
            )
        }

        let stoppedStore = WatchWorkoutRecoveryStore(
            persistence: ToggleRecoveryPersistence()
        )
        let stoppedManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: stoppedStore,
            initializeOnLaunch: false
        )
        let validStoppedBuilder = RecoveredIdentityProbe(
            metadata: WatchWorkoutManager.workoutIdentityMetadata(
                sessionID: UUID()
            ),
            sessionState: .stopped
        )
        let stoppedIdentity = await stoppedManager.recoverWorkoutIdentity(
            using: validStoppedBuilder.adapter(startDate: startDate)
        )
        XCTAssertNil(stoppedIdentity)
        XCTAssertNil(
            stoppedStore.recoveredIdentity,
            "a terminal builder UUID cannot reconstruct a lost Save/Discard choice"
        )

        let corruptPersistence = ToggleRecoveryPersistence()
        corruptPersistence.data = Data([0x00, 0x01, 0x02])
        let corruptStore = WatchWorkoutRecoveryStore(
            persistence: corruptPersistence
        )
        let corruptManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: corruptStore,
            initializeOnLaunch: false
        )
        let validCorruptBuilder = RecoveredIdentityProbe(
            metadata: WatchWorkoutManager.workoutIdentityMetadata(
                sessionID: UUID()
            ),
            sessionState: .running
        )
        let corruptIdentity = await corruptManager.recoverWorkoutIdentity(
            using: validCorruptBuilder.adapter(startDate: startDate)
        )
        XCTAssertNil(corruptIdentity)
        XCTAssertEqual(corruptPersistence.data, Data([0x00, 0x01, 0x02]))

        let durablePersistence = ToggleRecoveryPersistence()
        let durableStore = WatchWorkoutRecoveryStore(
            persistence: durablePersistence
        )
        let durableIdentity = try durableStore.begin(startDate: startDate)
        let durableManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: durableStore,
            initializeOnLaunch: false
        )
        let emptyBuilder = RecoveredIdentityProbe(
            metadata: [:],
            sessionState: .stopped
        )
        let repairedIdentity = await durableManager.recoverWorkoutIdentity(
            using: emptyBuilder.adapter(startDate: startDate)
        )
        XCTAssertEqual(repairedIdentity?.sessionID, durableIdentity.sessionID)
        XCTAssertEqual(emptyBuilder.attachCallCount, 1)
        XCTAssertEqual(
            WatchWorkoutManager.workoutIdentitySessionID(
                from: emptyBuilder.metadata
            ),
            durableIdentity.sessionID
        )

        let attachmentFailure = RecoveredIdentityProbe(
            metadata: [:],
            sessionState: .running
        )
        attachmentFailure.failsAttachment = true
        let identityAfterAttachmentFailure = await durableManager.recoverWorkoutIdentity(
            using: attachmentFailure.adapter(startDate: startDate)
        )
        XCTAssertNil(identityAfterAttachmentFailure)
        XCTAssertEqual(attachmentFailure.attachCallCount, 1)
        XCTAssertTrue(attachmentFailure.metadata.isEmpty)
        XCTAssertEqual(durableStore.recoveredIdentity, durableIdentity)

        var malformed = WatchWorkoutManager.workoutIdentityMetadata(
            sessionID: durableIdentity.sessionID
        )
        malformed.removeValue(forKey: HKMetadataKeySyncVersion)
        let malformedBuilder = RecoveredIdentityProbe(
            metadata: malformed,
            sessionState: .running
        )
        let malformedIdentity = await durableManager.recoverWorkoutIdentity(
            using: malformedBuilder.adapter(startDate: startDate)
        )
        XCTAssertNil(malformedIdentity)
        XCTAssertEqual(malformedBuilder.attachCallCount, 0)

        let mismatchedBuilder = RecoveredIdentityProbe(
            metadata: WatchWorkoutManager.workoutIdentityMetadata(
                sessionID: UUID()
            ),
            sessionState: .running
        )
        let mismatchedIdentity = await durableManager.recoverWorkoutIdentity(
            using: mismatchedBuilder.adapter(startDate: startDate)
        )
        XCTAssertNil(mismatchedIdentity)

        let failingPersistence = ToggleRecoveryPersistence()
        failingPersistence.failsSave = true
        let failingStore = WatchWorkoutRecoveryStore(
            persistence: failingPersistence
        )
        let failingManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: failingStore,
            initializeOnLaunch: false
        )
        let validFailingBuilder = RecoveredIdentityProbe(
            metadata: WatchWorkoutManager.workoutIdentityMetadata(
                sessionID: UUID()
            ),
            sessionState: .running
        )
        let failedIdentity = await failingManager.recoverWorkoutIdentity(
            using: validFailingBuilder.adapter(startDate: startDate)
        )
        XCTAssertNil(failedIdentity)
        XCTAssertNil(failingStore.recoveredIdentity)
    }

    func testLegacySavedTombstoneMigratesToSaveDisposition() throws {
        struct LegacyTombstone: Codable {
            let sessionID: UUID
            let startDate: Date
            let savedAt: Date
            let routeStatus: WorkoutRouteSaveStatus
        }
        struct LegacyState: Codable {
            let activeIdentity: WatchWorkoutRecoveryStore.Identity?
            let terminalTombstones: [LegacyTombstone]
        }

        let persistence = ToggleRecoveryPersistence()
        let sessionID = UUID()
        let startDate = Date(timeIntervalSinceReferenceDate: 800_037_000)
        persistence.data = try PropertyListEncoder().encode(
            LegacyState(
                activeIdentity: nil,
                terminalTombstones: [
                    LegacyTombstone(
                        sessionID: sessionID,
                        startDate: startDate,
                        savedAt: startDate.addingTimeInterval(60),
                        routeStatus: .present
                    )
                ]
            )
        )

        let migratedStore = WatchWorkoutRecoveryStore(
            persistence: persistence
        )
        let tombstone = migratedStore.terminalTombstone(
            externalUUID: sessionID.uuidString
        )
        XCTAssertEqual(tombstone?.disposition, .save)
        XCTAssertEqual(tombstone?.routeStatus, .present)
    }

    func testFinalizationRetryAcceptsStoppedAndEndedSessionsOnly() {
        XCTAssertTrue(
            WatchWorkoutManager.canRetryFinalization(sessionState: .stopped)
        )
        XCTAssertTrue(
            WatchWorkoutManager.canRetryFinalization(sessionState: .ended)
        )
        XCTAssertFalse(
            WatchWorkoutManager.canRetryFinalization(sessionState: .running)
        )
        XCTAssertFalse(
            WatchWorkoutManager.canRetryFinalization(sessionState: .paused)
        )
    }

    func testCorruptResetMetadataLessSessionsBecomeDiscardOnlyAcrossRelaunch() async throws {
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_685)
        let endDate = startDate.addingTimeInterval(60)
        let states: [HKWorkoutSessionState] = [
            .running,
            .paused,
            .stopped,
            .ended,
        ]

        for (index, state) in states.enumerated() {
            let persistence = ToggleRecoveryPersistence()
            persistence.data = Data([0x00, 0x01, 0x02])
            let corruptStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            try corruptStore.quarantineCorruptState()
            let resetStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            let manager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: resetStore,
                initializeOnLaunch: false
            )
            let metadata: [String: Any] = index.isMultiple(of: 2)
                ? [:]
                : [HKMetadataKeySyncVersion: 1]
            let probe = RecoveredIdentityProbe(
                metadata: metadata,
                sessionState: state,
                endDate: endDate
            )

            let cleanupIdentity = await manager.recoverWorkoutIdentity(
                using: probe.adapter(startDate: startDate)
            )
            XCTAssertEqual(cleanupIdentity?.finishRequest?.disposition, .discard)
            XCTAssertEqual(cleanupIdentity?.corruptResetPendingFinishChoice, true)
            XCTAssertEqual(
                probe.attachCallCount,
                0,
                "reset-authorized metadata-less cleanup must not depend on attaching a synthetic Save identity"
            )

            let relaunchedStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            let relaunchedManager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: relaunchedStore,
                initializeOnLaunch: false
            )
            let relaunchedProbe = RecoveredIdentityProbe(
                metadata: metadata,
                sessionState: state,
                endDate: endDate
            )
            let relaunchedIdentity = await relaunchedManager.recoverWorkoutIdentity(
                using: relaunchedProbe.adapter(startDate: startDate)
            )
            XCTAssertEqual(relaunchedIdentity?.sessionID, cleanupIdentity?.sessionID)
            XCTAssertEqual(relaunchedIdentity?.finishRequest?.disposition, .discard)
            XCTAssertEqual(relaunchedProbe.attachCallCount, 0)

            let detachedStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            let recovery = RecoveryProbe()
            var savedLookupCount = 0
            var saveFinalizationClaims: [WorkoutSaveFinalizationMode?] = []
            let detachedManager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: detachedStore,
                recoverActiveWorkoutSession: { await recovery.run() },
                savedWorkoutLookup: { _, _ in
                    savedLookupCount += 1
                    return nil
                },
                finalizationClaimObserver: {
                    saveFinalizationClaims.append($0)
                },
                initializeOnLaunch: false
            )
            detachedManager.retrySetup()
            try await waitUntil { recovery.callCount == 1 }
            recovery.completeWithoutSession()
            try await waitUntil {
                !detachedManager.isRecovering && detachedManager.state == .ending
            }
            XCTAssertEqual(savedLookupCount, 0)
            XCTAssertTrue(saveFinalizationClaims.isEmpty)
            XCTAssertNil(detachedManager.summary)
            XCTAssertEqual(
                detachedStore.recoveredIdentity?.finishRequest?.disposition,
                .discard
            )
        }
    }

    func testRecoveredMetadataLessSessionsExecuteProductionDiscardPathExactlyOnce() async throws {
        let states: [HKWorkoutSessionState] = [
            .running,
            .paused,
            .stopped,
            .ended,
        ]

        for state in states {
            let persistence = ToggleRecoveryPersistence()
            persistence.data = Data([0x00, 0x01, 0x02])
            let corruptStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            try corruptStore.quarantineCorruptState()
            let recoveryStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            let startDate = Date().addingTimeInterval(-180)
            let endDate = startDate.addingTimeInterval(90)
            var finalizationEvents: [String] = []
            var savedLookupCount = 0
            let manager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: recoveryStore,
                savedWorkoutLookup: { _, _ in
                    savedLookupCount += 1
                    return nil
                },
                recoveredDiscardFinalizationAdapter:
                    WatchRecoveredDiscardFinalizationAdapter(
                        discardWorkout: {
                            finalizationEvents.append("builder-discard")
                        },
                        discardRoute: {
                            finalizationEvents.append("route-discard")
                        },
                        endSession: {
                            finalizationEvents.append("session-end")
                        }
                    ),
                initializeOnLaunch: false
            )
            let probe = RecoveredIdentityProbe(
                metadata: [:],
                sessionState: state,
                endDate: endDate
            )
            let cleanupIdentity = await manager.recoverWorkoutIdentity(
                using: probe.adapter(startDate: startDate)
            )
            XCTAssertEqual(cleanupIdentity?.finishRequest?.disposition, .discard)
            XCTAssertTrue(
                manager.restoreDetachedFinalizationLifecycle(
                    from: try XCTUnwrap(cleanupIdentity)
                )
            )

            var stopCount = 0
            var finalizationCount = 0
            var sessionAdapter: WatchRecoveredDiscardSessionAdapter!
            sessionAdapter = WatchRecoveredDiscardSessionAdapter(
                stopSession: { date in
                    stopCount += 1
                    // Model the real HealthKit stopped callback after the
                    // production recovery path calls stopActivity.
                    manager.handleRecoveredDiscardSessionState(
                        .stopped,
                        transitionDate: date,
                        adapter: sessionAdapter
                    )
                },
                finalizeStoppedSession: { date in
                    finalizationCount += 1
                    manager.handleSessionReadyForFinalization(at: date)
                }
            )
            manager.handleRecoveredDiscardSessionState(
                state,
                transitionDate: endDate,
                adapter: sessionAdapter
            )
            try await waitUntil {
                finalizationEvents.count == 3
                    && recoveryStore.recoveredIdentity == nil
            }

            XCTAssertEqual(
                stopCount,
                [.running, .paused].contains(state) ? 1 : 0
            )
            XCTAssertEqual(finalizationCount, 1)
            XCTAssertEqual(
                finalizationEvents,
                ["builder-discard", "route-discard", "session-end"]
            )
            XCTAssertEqual(probe.attachCallCount, 0)
            XCTAssertEqual(savedLookupCount, 0)
            XCTAssertNil(manager.finishRequestError)
            XCTAssertEqual(manager.summary?.outcome, .discarded)
        }
    }

    func testLateHealthKitUUIDBindsAtomicallyBeforeRecoveredDiscard() async throws {
        let persistence = ToggleRecoveryPersistence()
        persistence.data = Data([0x00, 0x01, 0x02])
        let corruptStore = WatchWorkoutRecoveryStore(persistence: persistence)
        try corruptStore.quarantineCorruptState()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let startDate = Date().addingTimeInterval(-180)
        let endDate = startDate.addingTimeInterval(90)
        let realHealthKitSessionID = UUID()
        var finalizationMetadata: [String: Any] = [:]
        var finalizationEvents: [String] = []
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoveredDiscardFinalizationAdapter:
                WatchRecoveredDiscardFinalizationAdapter(
                    metadata: { finalizationMetadata },
                    discardWorkout: {
                        finalizationEvents.append("builder-discard")
                    },
                    discardRoute: {
                        finalizationEvents.append("route-discard")
                    },
                    endSession: {
                        finalizationEvents.append("session-end")
                    }
                ),
            initializeOnLaunch: false
        )
        let probe = RecoveredIdentityProbe(
            metadata: [:],
            sessionState: .stopped,
            endDate: endDate
        )
        let recoveredIdentity = await manager.recoverWorkoutIdentity(
            using: probe.adapter(startDate: startDate)
        )
        let syntheticIdentity = try XCTUnwrap(recoveredIdentity)
        XCTAssertEqual(
            syntheticIdentity.corruptResetSyntheticCleanupIdentity,
            true
        )
        XCTAssertNil(syntheticIdentity.healthKitSessionID)
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(from: syntheticIdentity)
        )

        // HealthKit exposes the genuine UUID only after adoption, while the
        // stopped-session callback is about to enter destructive finalization.
        finalizationMetadata = WatchWorkoutManager.workoutIdentityMetadata(
            sessionID: realHealthKitSessionID
        )
        persistence.failOnSaveCall = persistence.saveCallCount + 1
        manager.handleRecoveredDiscardSessionState(
            .stopped,
            transitionDate: endDate,
            adapter: WatchRecoveredDiscardSessionAdapter(
                stopSession: { _ in
                    XCTFail("stopped recovery must not be stopped again")
                },
                finalizeStoppedSession: { date in
                    manager.handleSessionReadyForFinalization(at: date)
                }
            )
        )
        try await waitUntil {
            manager.finishRequestError == .reconciliationFailed
        }
        XCTAssertTrue(finalizationEvents.isEmpty)

        let failedBindRelaunch = WatchWorkoutRecoveryStore(
            persistence: persistence
        )
        XCTAssertEqual(failedBindRelaunch.recoveredIdentity, syntheticIdentity)
        XCTAssertNil(
            failedBindRelaunch.terminalTombstone(
                externalUUID: realHealthKitSessionID.uuidString
            )
        )

        persistence.failOnSaveCall = nil
        let relaunchedManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: failedBindRelaunch,
            recoveredDiscardFinalizationAdapter:
                WatchRecoveredDiscardFinalizationAdapter(
                    metadata: { finalizationMetadata },
                    discardWorkout: {
                        finalizationEvents.append("builder-discard")
                    },
                    discardRoute: {
                        finalizationEvents.append("route-discard")
                    },
                    endSession: {
                        finalizationEvents.append("session-end")
                    }
                ),
            initializeOnLaunch: false
        )
        let relaunchedProbe = RecoveredIdentityProbe(
            metadata: finalizationMetadata,
            sessionState: .stopped,
            endDate: endDate
        )
        let relaunchedRecoveredIdentity = await relaunchedManager
            .recoverWorkoutIdentity(
                using: relaunchedProbe.adapter(startDate: startDate)
            )
        let reboundIdentity = try XCTUnwrap(
            relaunchedRecoveredIdentity
        )
        XCTAssertEqual(reboundIdentity.sessionID, syntheticIdentity.sessionID)
        XCTAssertEqual(
            reboundIdentity.healthKitSessionID,
            realHealthKitSessionID
        )
        XCTAssertTrue(
            relaunchedManager.restoreDetachedFinalizationLifecycle(
                from: reboundIdentity
            )
        )
        let relaunchedSessionAdapter = WatchRecoveredDiscardSessionAdapter(
            stopSession: { _ in
                XCTFail("stopped recovery must not be stopped again")
            },
            finalizeStoppedSession: { date in
                relaunchedManager.handleSessionReadyForFinalization(at: date)
            }
        )
        relaunchedManager.handleRecoveredDiscardSessionState(
            .stopped,
            transitionDate: endDate,
            adapter: relaunchedSessionAdapter
        )
        relaunchedManager.handleRecoveredDiscardSessionState(
            .stopped,
            transitionDate: endDate,
            adapter: relaunchedSessionAdapter
        )
        try await waitUntil {
            finalizationEvents.count == 3
                && failedBindRelaunch.recoveredIdentity == nil
        }
        XCTAssertEqual(
            finalizationEvents,
            ["builder-discard", "route-discard", "session-end"]
        )
        XCTAssertNil(
            failedBindRelaunch.terminalTombstone(
                externalUUID: syntheticIdentity.sessionID.uuidString
            )
        )
        XCTAssertEqual(
            failedBindRelaunch.terminalTombstone(
                externalUUID: realHealthKitSessionID.uuidString
            )?.disposition,
            .discard
        )

        // Model the queued real-UUID recovery callback. The production
        // terminal cleanup path must consume the matching tombstone after
        // discarding the duplicate builder and ending its session.
        var queuedCallbackEvents: [String] = []
        let queuedOutcome = relaunchedManager
            .recoverTerminalTombstoneSessionIfPresent(
                using: WatchRecoveredTerminalSessionAdapter(
                    metadata: { finalizationMetadata },
                    startDate: startDate,
                    sessionState: { .stopped },
                    attachRuntime: {
                        queuedCallbackEvents.append("session-attach")
                    },
                    stopSession: { _ in
                        XCTFail("stopped tombstone must not be stopped again")
                    },
                    discardWorkout: {
                        queuedCallbackEvents.append("builder-discard")
                    },
                    endSession: {
                        queuedCallbackEvents.append("session-end")
                    },
                    releaseSession: {
                        queuedCallbackEvents.append("session-release")
                    }
                ),
                transitionDate: endDate
            )
        XCTAssertEqual(queuedOutcome, .recovered)
        XCTAssertEqual(
            queuedCallbackEvents,
            [
                "session-attach",
                "builder-discard",
                "session-end",
                "session-release"
            ]
        )
        XCTAssertNil(
            failedBindRelaunch.terminalTombstone(
                externalUUID: realHealthKitSessionID.uuidString
            )
        )
    }

    func testHealthKitUUIDAppearingAfterFinalReadMatchesSyntheticDiscardTombstone() async throws {
        let persistence = ToggleRecoveryPersistence()
        persistence.data = Data([0x00, 0x01, 0x02])
        let corruptStore = WatchWorkoutRecoveryStore(persistence: persistence)
        try corruptStore.quarantineCorruptState()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let startDate = Date(timeIntervalSinceReferenceDate: 800_060_000)
        let endDate = startDate.addingTimeInterval(90)
        let realHealthKitSessionID = UUID()
        var finalizationMetadata: [String: Any] = [:]
        var finalizationEvents: [String] = []
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoveredDiscardFinalizationAdapter:
                WatchRecoveredDiscardFinalizationAdapter(
                    metadata: { finalizationMetadata },
                    discardWorkout: {
                        // The final metadata read has already returned empty.
                        // Model HealthKit publishing its UUID only as discard
                        // begins and queues a later recovery callback.
                        finalizationMetadata =
                            WatchWorkoutManager.workoutIdentityMetadata(
                                sessionID: realHealthKitSessionID
                            )
                        finalizationEvents.append("builder-discard")
                    },
                    discardRoute: {
                        finalizationEvents.append("route-discard")
                    },
                    endSession: {
                        finalizationEvents.append("session-end")
                    }
                ),
            initializeOnLaunch: false
        )
        let probe = RecoveredIdentityProbe(
            metadata: [:],
            sessionState: .stopped,
            endDate: endDate
        )
        let recoveredIdentity = await manager.recoverWorkoutIdentity(
            using: probe.adapter(startDate: startDate)
        )
        let syntheticIdentity = try XCTUnwrap(recoveredIdentity)
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(from: syntheticIdentity)
        )

        manager.handleRecoveredDiscardSessionState(
            .stopped,
            transitionDate: endDate,
            adapter: WatchRecoveredDiscardSessionAdapter(
                stopSession: { _ in
                    XCTFail("stopped recovery must not be stopped again")
                },
                finalizeStoppedSession: { date in
                    manager.handleSessionReadyForFinalization(at: date)
                }
            )
        )
        try await waitUntil {
            finalizationEvents.count == 3
                && recoveryStore.recoveredIdentity == nil
        }
        XCTAssertEqual(
            finalizationEvents,
            ["builder-discard", "route-discard", "session-end"]
        )
        let relaunchedStore = WatchWorkoutRecoveryStore(
            persistence: persistence
        )
        let relaunchedManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: relaunchedStore,
            initializeOnLaunch: false
        )
        XCTAssertNil(
            relaunchedStore.terminalTombstone(
                externalUUID: realHealthKitSessionID.uuidString
            )
        )

        let unresolvedTombstone = try XCTUnwrap(
            relaunchedStore.terminalTombstone(
                externalUUID: syntheticIdentity.sessionID.uuidString
            )
        )
        XCTAssertEqual(unresolvedTombstone.disposition, .discard)
        XCTAssertTrue(unresolvedTombstone.allowsLateHealthKitSessionIDMatch)
        XCTAssertNil(
            relaunchedManager.terminalTombstoneForRecoveredSession(
                metadata: finalizationMetadata,
                startDate: startDate.addingTimeInterval(0.001)
            )
        )

        var queuedCallbackEvents: [String] = []
        let queuedOutcome = relaunchedManager
            .recoverTerminalTombstoneSessionIfPresent(
                using: WatchRecoveredTerminalSessionAdapter(
                    metadata: { finalizationMetadata },
                    startDate: startDate,
                    sessionState: { .stopped },
                    attachRuntime: {
                        queuedCallbackEvents.append("session-attach")
                    },
                    stopSession: { _ in
                        XCTFail("stopped tombstone must not be stopped again")
                    },
                    discardWorkout: {
                        queuedCallbackEvents.append("builder-discard")
                    },
                    endSession: {
                        queuedCallbackEvents.append("session-end")
                    },
                    releaseSession: {
                        queuedCallbackEvents.append("session-release")
                    }
                ),
                transitionDate: endDate
            )
        XCTAssertEqual(queuedOutcome, .recovered)
        XCTAssertEqual(
            queuedCallbackEvents,
            [
                "session-attach",
                "builder-discard",
                "session-end",
                "session-release"
            ]
        )
        XCTAssertNil(
            relaunchedStore.terminalTombstone(
                externalUUID: syntheticIdentity.sessionID.uuidString
            )
        )
        XCTAssertNil(
            relaunchedManager.terminalTombstoneForRecoveredSession(
                metadata: finalizationMetadata,
                startDate: startDate
            )
        )
    }

    func testLateHealthKitFallbackRejectsEveryIneligibleTombstoneAndUUID() throws {
        let savedStore = WatchWorkoutRecoveryStore(
            persistence: ToggleRecoveryPersistence()
        )
        let savedIdentity = try archiveSavedIdentity(in: savedStore)
        let savedTombstone = try XCTUnwrap(
            savedStore.terminalTombstone(
                externalUUID: savedIdentity.sessionID.uuidString
            )
        )
        XCTAssertFalse(savedTombstone.allowsLateHealthKitSessionIDMatch)
        XCTAssertNil(
            savedStore.terminalTombstone(
                externalUUID: UUID().uuidString,
                recoveredSessionStartDate: savedIdentity.startDate
            )
        )

        let discardStore = WatchWorkoutRecoveryStore(
            persistence: ToggleRecoveryPersistence()
        )
        let discardIdentity = try archiveDiscardedIdentity(in: discardStore)
        let discardTombstone = try XCTUnwrap(
            discardStore.terminalTombstone(
                externalUUID: discardIdentity.sessionID.uuidString
            )
        )
        XCTAssertFalse(discardTombstone.allowsLateHealthKitSessionIDMatch)
        XCTAssertNil(
            discardStore.terminalTombstone(
                externalUUID: UUID().uuidString,
                recoveredSessionStartDate: discardIdentity.startDate
            )
        )

        let boundPersistence = ToggleRecoveryPersistence()
        boundPersistence.data = Data([0x00, 0x01, 0x02])
        let boundCorruptStore = WatchWorkoutRecoveryStore(
            persistence: boundPersistence
        )
        try boundCorruptStore.quarantineCorruptState()
        let boundStore = WatchWorkoutRecoveryStore(
            persistence: boundPersistence
        )
        let boundStartDate = Date().addingTimeInterval(-30)
        _ = try boundStore.useCorruptResetDiscardIdentity(
            startDate: boundStartDate,
            requestedAt: boundStartDate.addingTimeInterval(20)
        )
        let boundHealthKitSessionID = UUID()
        _ = try boundStore.useRecoveredIdentity(
            startDate: boundStartDate,
            stableSessionID: boundHealthKitSessionID
        )
        _ = try boundStore.archiveConfirmedDiscardedIdentity(
            at: boundStartDate.addingTimeInterval(21)
        )
        let boundTombstone = try XCTUnwrap(
            boundStore.terminalTombstone(
                externalUUID: boundHealthKitSessionID.uuidString
            )
        )
        XCTAssertFalse(boundTombstone.allowsLateHealthKitSessionIDMatch)
        XCTAssertNil(
            boundStore.terminalTombstone(
                externalUUID: UUID().uuidString,
                recoveredSessionStartDate: boundStartDate
            )
        )

        let unresolvedPersistence = ToggleRecoveryPersistence()
        unresolvedPersistence.data = Data([0x00, 0x01, 0x02])
        let unresolvedCorruptStore = WatchWorkoutRecoveryStore(
            persistence: unresolvedPersistence
        )
        try unresolvedCorruptStore.quarantineCorruptState()
        let unresolvedStore = WatchWorkoutRecoveryStore(
            persistence: unresolvedPersistence
        )
        let unresolvedStartDate = Date().addingTimeInterval(-20)
        let unresolvedIdentity = try unresolvedStore
            .useCorruptResetDiscardIdentity(
                startDate: unresolvedStartDate,
                requestedAt: unresolvedStartDate.addingTimeInterval(10)
            )
        _ = try unresolvedStore.archiveConfirmedDiscardedIdentity(
            at: unresolvedStartDate.addingTimeInterval(11)
        )
        XCTAssertTrue(
            try XCTUnwrap(
                unresolvedStore.terminalTombstone(
                    externalUUID: unresolvedIdentity.sessionID.uuidString
                )
            ).allowsLateHealthKitSessionIDMatch
        )
        let zeroUUID = "00000000-0000-0000-0000-000000000000"
        for invalidExternalUUID in [nil, "not-a-uuid", zeroUUID] {
            XCTAssertNil(
                unresolvedStore.terminalTombstone(
                    externalUUID: invalidExternalUUID,
                    recoveredSessionStartDate: unresolvedStartDate
                ),
                "unexpected fallback for \(invalidExternalUUID ?? "nil")"
            )
        }
    }

    func testCorruptResetAuthorizationSurvivesACompleteNewRideBeforeLateCleanup() async throws {
        let persistence = ToggleRecoveryPersistence()
        persistence.data = Data([0x00, 0x01, 0x02])
        let corruptStore = WatchWorkoutRecoveryStore(
            persistence: persistence
        )
        try corruptStore.quarantineCorruptState()

        // The system can initially report no active workout even though a late
        // callback for the abandoned metadata-less session is still possible.
        let recovery = RecoveryProbe()
        let authorizationRefresh = AsyncVoidProbe()
        let setupStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let setupManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: setupStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            refreshAuthorization: { await authorizationRefresh.run() },
            initializeOnLaunch: false
        )
        setupManager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { authorizationRefresh.callCount == 1 }
        authorizationRefresh.complete()
        try await waitUntil { !setupManager.isRecovering }
        XCTAssertTrue(setupStore.hasCorruptResetAuthorization)
        XCTAssertNil(setupStore.recoveredIdentity)

        // Exercise the production persistence lifecycle for a completely new
        // rider-started workout. Its start, save, and archive must not consume
        // the independent authority to discard the abandoned old session.
        let newRideStart = Date(timeIntervalSinceReferenceDate: 800_036_900)
        let newRide = try setupStore.begin(startDate: newRideStart)
        XCTAssertTrue(setupStore.hasCorruptResetAuthorization)
        let duringRideStore = WatchWorkoutRecoveryStore(persistence: persistence)
        XCTAssertEqual(duringRideStore.recoveredIdentity?.sessionID, newRide.sessionID)
        XCTAssertTrue(duringRideStore.hasCorruptResetAuthorization)
        try duringRideStore.markFinishing(
            disposition: .save,
            requestedAt: newRideStart.addingTimeInterval(60)
        )
        try duringRideStore.markCollectionEnded()
        try duringRideStore.markFinishAttempted()
        try duringRideStore.markWorkoutSaved()
        _ = try duringRideStore.archiveConfirmedSavedIdentity(
            at: newRideStart.addingTimeInterval(61)
        )

        let afterNewRideStore = WatchWorkoutRecoveryStore(persistence: persistence)
        XCTAssertNil(afterNewRideStore.recoveredIdentity)
        XCTAssertTrue(afterNewRideStore.hasCorruptResetAuthorization)
        XCTAssertEqual(
            afterNewRideStore.terminalTombstone(
                externalUUID: newRide.sessionID.uuidString
            )?.disposition,
            .save
        )

        var savedLookupCount = 0
        var saveFinalizationClaims: [WorkoutSaveFinalizationMode?] = []
        let lateManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: afterNewRideStore,
            savedWorkoutLookup: { _, _ in
                savedLookupCount += 1
                return nil
            },
            finalizationClaimObserver: {
                saveFinalizationClaims.append($0)
            },
            initializeOnLaunch: false
        )
        let oldStart = newRideStart.addingTimeInterval(-300)
        let oldProbe = RecoveredIdentityProbe(
            metadata: [:],
            sessionState: .stopped,
            endDate: oldStart.addingTimeInterval(120)
        )
        let cleanupIdentity = await lateManager.recoverWorkoutIdentity(
            using: oldProbe.adapter(startDate: oldStart)
        )
        XCTAssertEqual(cleanupIdentity?.finishRequest?.disposition, .discard)
        XCTAssertEqual(cleanupIdentity?.corruptResetPendingFinishChoice, true)
        XCTAssertEqual(cleanupIdentity?.corruptResetSyntheticCleanupIdentity, true)
        XCTAssertFalse(afterNewRideStore.hasCorruptResetAuthorization)
        XCTAssertEqual(oldProbe.attachCallCount, 0)
        XCTAssertEqual(savedLookupCount, 0)
        XCTAssertTrue(saveFinalizationClaims.isEmpty)

        let futurePersistence = ToggleRecoveryPersistence()
        futurePersistence.data = Data([0x00, 0x01, 0x02])
        let futureCorruptStore = WatchWorkoutRecoveryStore(
            persistence: futurePersistence
        )
        try futureCorruptStore.quarantineCorruptState()
        let futureStore = WatchWorkoutRecoveryStore(
            persistence: futurePersistence
        )
        let futureManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: futureStore,
            initializeOnLaunch: false
        )
        let futureStart = Date().addingTimeInterval(60)
        let futureProbe = RecoveredIdentityProbe(
            metadata: [:],
            sessionState: .stopped,
            endDate: futureStart.addingTimeInterval(30)
        )
        let futureIdentity = await futureManager.recoverWorkoutIdentity(
            using: futureProbe.adapter(startDate: futureStart)
        )
        XCTAssertNil(
            futureIdentity,
            "reset authority must never discard a workout that starts after rider approval"
        )
        XCTAssertTrue(futureStore.hasCorruptResetAuthorization)
        XCTAssertNil(futureStore.recoveredIdentity)
        let futureRelaunch = WatchWorkoutRecoveryStore(
            persistence: futurePersistence
        )
        XCTAssertTrue(futureRelaunch.hasCorruptResetAuthorization)
        XCTAssertFalse(
            futureRelaunch.authorizesCorruptResetRecovery(
                startDate: futureStart
            )
        )
    }

    func testNilRecoveryCannotReplaceNewerRideWhileResetAuthorityWaitsForOldSession() async throws {
        let persistence = ToggleRecoveryPersistence()
        persistence.data = Data([0x00, 0x01, 0x02])
        let corruptStore = WatchWorkoutRecoveryStore(persistence: persistence)
        try corruptStore.quarantineCorruptState()

        let newerRideStart = Date().addingTimeInterval(60)
        let newerRide = try corruptStore.begin(startDate: newerRideStart)
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        XCTAssertTrue(recoveryStore.hasCorruptResetAuthorization)
        XCTAssertEqual(recoveryStore.recoveredIdentity, newerRide)

        let recovery = RecoveryProbe()
        let authorizationRefresh = AsyncVoidProbe()
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            refreshAuthorization: { await authorizationRefresh.run() },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { authorizationRefresh.callCount == 1 }
        authorizationRefresh.complete()
        try await waitUntil { !manager.isRecovering }

        XCTAssertEqual(manager.setupState, .failed)
        XCTAssertTrue(manager.hasPendingWorkoutRecovery)
        XCTAssertEqual(recoveryStore.recoveredIdentity, newerRide)
        XCTAssertTrue(recoveryStore.hasCorruptResetAuthorization)

        // Exercise the production Start path even though the failed setup UI
        // hides its button. A stale queued tap must fail before authorization
        // or begin() and may never clear the recoverable newer ride.
        await manager.startOutdoorCyclingWorkout()
        XCTAssertEqual(manager.setupState, .failed)
        XCTAssertEqual(recoveryStore.recoveredIdentity, newerRide)

        let lateProbe = RecoveredIdentityProbe(
            metadata: WatchWorkoutManager.workoutIdentityMetadata(
                sessionID: newerRide.sessionID
            ),
            sessionState: .running
        )
        let lateIdentity = await manager.recoverWorkoutIdentity(
            using: lateProbe.adapter(startDate: newerRideStart)
        )
        XCTAssertEqual(lateIdentity?.sessionID, newerRide.sessionID)
        XCTAssertNil(lateIdentity?.corruptResetPendingFinishChoice)
        XCTAssertNil(lateIdentity?.finishRequest)
        XCTAssertEqual(lateProbe.attachCallCount, 0)

        let disposition = try recoveryStore.markFinishing(
            disposition: .save,
            requestedAt: newerRideStart.addingTimeInterval(120)
        )
        XCTAssertEqual(disposition, .save)
        XCTAssertTrue(
            recoveryStore.hasCorruptResetAuthorization,
            "normal recovery must not consume authority reserved for the pre-reset session"
        )
        XCTAssertFalse(
            recoveryStore.authorizesCorruptResetRecovery(
                startDate: newerRideStart
            )
        )
    }

    func testRecoverySignalInvalidatesStartSuspendedInAuthorization() async throws {
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let authorizationRequest = AsyncThrowingVoidProbe()
        let authorizationRefresh = AsyncVoidProbe()
        let recovery = RecoveryProbe()
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            requestAuthorization: { try await authorizationRequest.run() },
            refreshAuthorization: { await authorizationRefresh.run() },
            authorizationRefreshState: .ready,
            initializeOnLaunch: false
        )

        let startTask = Task {
            await manager.startOutdoorCyclingWorkout()
        }
        try await waitUntil { authorizationRequest.callCount == 1 }

        manager.handleActiveWorkoutRecovery()
        try await waitUntil {
            manager.isRecovering && recovery.callCount == 1
        }

        // Let authorization report Ready while the active-session query is
        // still suspended. The stale Start continuation must not cross the
        // recovery generation boundary.
        authorizationRequest.complete()
        try await waitUntil { authorizationRefresh.callCount == 1 }
        authorizationRefresh.complete()
        await startTask.value

        XCTAssertTrue(manager.isRecovering)
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isWorkoutActive)
        XCTAssertFalse(manager.hasPendingWorkoutRecovery)
        XCTAssertNil(recoveryStore.recoveredIdentity)

        recovery.completeWithoutSession()
        try await waitUntil { authorizationRefresh.callCount == 2 }
        authorizationRefresh.complete()
        try await waitUntil { !manager.isRecovering }
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(recoveryStore.recoveredIdentity)
    }

    func testCorruptResetSyntheticCleanupRebindsOnceToRealHealthKitUUID() async throws {
        let persistence = ToggleRecoveryPersistence()
        persistence.data = Data([0x00, 0x01, 0x02])
        let corruptStore = WatchWorkoutRecoveryStore(persistence: persistence)
        try corruptStore.quarantineCorruptState()
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_950)
        let endDate = startDate.addingTimeInterval(90)

        let firstStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let firstManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: firstStore,
            initializeOnLaunch: false
        )
        let metadataLessProbe = RecoveredIdentityProbe(
            metadata: [:],
            sessionState: .stopped,
            endDate: endDate
        )
        let syntheticIdentity = await firstManager.recoverWorkoutIdentity(
            using: metadataLessProbe.adapter(startDate: startDate)
        )
        XCTAssertEqual(
            syntheticIdentity?.corruptResetSyntheticCleanupIdentity,
            true
        )
        XCTAssertEqual(syntheticIdentity?.finishRequest?.disposition, .discard)
        XCTAssertEqual(metadataLessProbe.attachCallCount, 0)

        // The detached production path may publish before HealthKit's UUID is
        // visible. Capture that real manager envelope before simulating a crash.
        let firstRecovery = RecoveryProbe()
        let publishingStore = WatchWorkoutRecoveryStore(
            persistence: persistence
        )
        let publishingManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: publishingStore,
            recoverActiveWorkoutSession: { await firstRecovery.run() },
            initializeOnLaunch: false
        )
        publishingManager.retrySetup()
        try await waitUntil { firstRecovery.callCount == 1 }
        firstRecovery.completeWithoutSession()
        try await waitUntil { !publishingManager.isRecovering }
        let syntheticEnvelope = try XCTUnwrap(
            publishingManager.latestEnvelope
        )
        XCTAssertEqual(syntheticEnvelope.sessionID, syntheticIdentity?.sessionID)
        XCTAssertEqual(syntheticEnvelope.snapshot?.state, .ending)
        let identityBeforeBind = try XCTUnwrap(
            publishingStore.recoveredIdentity
        )

        // HealthKit can expose the genuine UUID on a later callback. Replace
        // only the marked synthetic cleanup UUID while retaining discard-only
        // provenance and all transport ordering state.
        let realSessionID = UUID()
        let reboundStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let reboundManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: reboundStore,
            initializeOnLaunch: false
        )
        let identifiedProbe = RecoveredIdentityProbe(
            metadata: WatchWorkoutManager.workoutIdentityMetadata(
                sessionID: realSessionID
            ),
            sessionState: .stopped,
            endDate: endDate
        )
        let reboundIdentity = await reboundManager.recoverWorkoutIdentity(
            using: identifiedProbe.adapter(startDate: startDate)
        )
        XCTAssertEqual(reboundIdentity?.sessionID, syntheticIdentity?.sessionID)
        XCTAssertEqual(reboundIdentity?.healthKitSessionID, realSessionID)
        XCTAssertEqual(reboundIdentity?.finishRequest?.disposition, .discard)
        XCTAssertEqual(reboundIdentity?.corruptResetPendingFinishChoice, true)
        XCTAssertEqual(
            reboundIdentity?.corruptResetSyntheticCleanupIdentity,
            true
        )
        XCTAssertEqual(
            reboundIdentity?.sessionToken,
            syntheticIdentity?.sessionToken
        )
        XCTAssertEqual(
            reboundIdentity?.transportGenerationID,
            syntheticIdentity?.transportGenerationID
        )
        XCTAssertEqual(
            reboundIdentity?.sequenceHighWatermark,
            identityBeforeBind.sequenceHighWatermark
        )
        XCTAssertEqual(identifiedProbe.attachCallCount, 0)

        let relaunchedStore = WatchWorkoutRecoveryStore(persistence: persistence)
        XCTAssertEqual(relaunchedStore.recoveredIdentity, reboundIdentity)
        XCTAssertFalse(relaunchedStore.hasCorruptResetAuthorization)
        XCTAssertTrue(relaunchedStore.hasCorruptResetPendingIdentity)

        let replacementID = UUID()
        XCTAssertThrowsError(
            try relaunchedStore.useRecoveredIdentity(
                startDate: startDate,
                stableSessionID: replacementID
            )
        )
        XCTAssertEqual(
            relaunchedStore.recoveredIdentity?.healthKitSessionID,
            realSessionID,
            "a genuine HealthKit UUID must never be rebound a second time"
        )

        let terminalStore = WatchWorkoutRecoveryStore(
            persistence: persistence
        )
        let terminalManager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: terminalStore,
            initializeOnLaunch: false
        )
        XCTAssertTrue(
            terminalManager.restoreDetachedFinalizationLifecycle(
                from: try XCTUnwrap(terminalStore.recoveredIdentity)
            )
        )
        terminalManager.completeConfirmedDiscard(
            summary: WatchWorkoutSummary(
                outcome: .discarded,
                endedAt: endDate,
                duration: endDate.timeIntervalSince(startDate),
                distanceMeters: nil,
                activeEnergyKilocalories: nil,
                averageHeartRate: nil,
                routeStatus: .unavailable
            ),
            discardedAt: endDate
        )
        let terminalEnvelope = try XCTUnwrap(terminalManager.latestEnvelope)
        XCTAssertEqual(terminalEnvelope.snapshot?.state, .ended)
        XCTAssertEqual(terminalEnvelope.sessionID, syntheticEnvelope.sessionID)
        XCTAssertGreaterThan(terminalEnvelope.sequence, syntheticEnvelope.sequence)
        var receiver = WorkoutEnvelopeSequenceGate()
        XCTAssertTrue(try receiver.ingest(syntheticEnvelope))
        XCTAssertTrue(
            try receiver.ingest(terminalEnvelope),
            "late HealthKit UUID binding must not change receiver transport identity"
        )
        XCTAssertEqual(
            terminalStore.terminalTombstone(
                externalUUID: realSessionID.uuidString
            )?.disposition,
            .discard
        )
    }

    func testCorruptResetTransitionsAreFailureAtomicAcrossRelaunch() async throws {
        let ridePersistence = ToggleRecoveryPersistence()
        ridePersistence.data = Data([0x00, 0x01, 0x02])
        let corruptRideStore = WatchWorkoutRecoveryStore(
            persistence: ridePersistence
        )
        try corruptRideStore.quarantineCorruptState()
        let rideStore = WatchWorkoutRecoveryStore(
            persistence: ridePersistence
        )
        let authorizationBytes = try XCTUnwrap(ridePersistence.data)
        let rideStart = Date().addingTimeInterval(30)

        ridePersistence.failsSave = true
        XCTAssertThrowsError(try rideStore.begin(startDate: rideStart))
        XCTAssertEqual(ridePersistence.data, authorizationBytes)
        XCTAssertNil(rideStore.recoveredIdentity)
        XCTAssertTrue(rideStore.hasCorruptResetAuthorization)
        let failedBeginRelaunch = WatchWorkoutRecoveryStore(
            persistence: ridePersistence
        )
        XCTAssertNil(failedBeginRelaunch.recoveredIdentity)
        XCTAssertTrue(failedBeginRelaunch.hasCorruptResetAuthorization)

        ridePersistence.failsSave = false
        let newRide = try failedBeginRelaunch.begin(startDate: rideStart)
        XCTAssertTrue(failedBeginRelaunch.hasCorruptResetAuthorization)
        try failedBeginRelaunch.markFinishing(
            disposition: .save,
            requestedAt: rideStart.addingTimeInterval(60)
        )
        try failedBeginRelaunch.markCollectionEnded()
        try failedBeginRelaunch.markFinishAttempted()
        try failedBeginRelaunch.markWorkoutSaved()
        let identityBeforeArchive = try XCTUnwrap(
            failedBeginRelaunch.recoveredIdentity
        )
        let beforeArchiveBytes = try XCTUnwrap(ridePersistence.data)

        ridePersistence.failsSave = true
        XCTAssertThrowsError(
            try failedBeginRelaunch.archiveConfirmedSavedIdentity(
                at: rideStart.addingTimeInterval(61)
            )
        )
        XCTAssertEqual(ridePersistence.data, beforeArchiveBytes)
        XCTAssertEqual(
            failedBeginRelaunch.recoveredIdentity,
            identityBeforeArchive
        )
        XCTAssertTrue(failedBeginRelaunch.hasCorruptResetAuthorization)
        let failedArchiveRelaunch = WatchWorkoutRecoveryStore(
            persistence: ridePersistence
        )
        XCTAssertEqual(
            failedArchiveRelaunch.recoveredIdentity,
            identityBeforeArchive
        )
        XCTAssertTrue(failedArchiveRelaunch.hasCorruptResetAuthorization)

        ridePersistence.failsSave = false
        _ = try failedArchiveRelaunch.archiveConfirmedSavedIdentity(
            at: rideStart.addingTimeInterval(61)
        )
        let archivedRelaunch = WatchWorkoutRecoveryStore(
            persistence: ridePersistence
        )
        XCTAssertNil(archivedRelaunch.recoveredIdentity)
        XCTAssertTrue(archivedRelaunch.hasCorruptResetAuthorization)
        XCTAssertEqual(
            archivedRelaunch.terminalTombstone(
                externalUUID: newRide.sessionID.uuidString
            )?.disposition,
            .save
        )

        let cleanupPersistence = ToggleRecoveryPersistence()
        cleanupPersistence.data = Data([0x00, 0x01, 0x02])
        let corruptCleanupStore = WatchWorkoutRecoveryStore(
            persistence: cleanupPersistence
        )
        try corruptCleanupStore.quarantineCorruptState()
        let cleanupStore = WatchWorkoutRecoveryStore(
            persistence: cleanupPersistence
        )
        let oldStart = Date().addingTimeInterval(-120)
        let cleanupEnd = oldStart.addingTimeInterval(60)
        let beforeCleanupBytes = try XCTUnwrap(cleanupPersistence.data)

        cleanupPersistence.failsSave = true
        XCTAssertThrowsError(
            try cleanupStore.useCorruptResetDiscardIdentity(
                startDate: oldStart,
                requestedAt: cleanupEnd
            )
        )
        XCTAssertEqual(cleanupPersistence.data, beforeCleanupBytes)
        XCTAssertNil(cleanupStore.recoveredIdentity)
        XCTAssertTrue(cleanupStore.hasCorruptResetAuthorization)
        let failedCleanupRelaunch = WatchWorkoutRecoveryStore(
            persistence: cleanupPersistence
        )
        XCTAssertNil(failedCleanupRelaunch.recoveredIdentity)
        XCTAssertTrue(failedCleanupRelaunch.hasCorruptResetAuthorization)

        cleanupPersistence.failsSave = false
        _ = try failedCleanupRelaunch.useCorruptResetDiscardIdentity(
            startDate: oldStart,
            requestedAt: cleanupEnd
        )
        _ = failedCleanupRelaunch.nextSequence()
        let identityBeforeBind = try XCTUnwrap(
            failedCleanupRelaunch.recoveredIdentity
        )
        let beforeBindBytes = try XCTUnwrap(cleanupPersistence.data)
        let realSessionID = UUID()

        cleanupPersistence.failsSave = true
        XCTAssertThrowsError(
            try failedCleanupRelaunch.useRecoveredIdentity(
                startDate: oldStart,
                stableSessionID: realSessionID
            )
        )
        XCTAssertEqual(cleanupPersistence.data, beforeBindBytes)
        XCTAssertEqual(
            failedCleanupRelaunch.recoveredIdentity,
            identityBeforeBind
        )
        let failedBindRelaunch = WatchWorkoutRecoveryStore(
            persistence: cleanupPersistence
        )
        XCTAssertEqual(failedBindRelaunch.recoveredIdentity, identityBeforeBind)

        cleanupPersistence.failsSave = false
        let rebound = try failedBindRelaunch.useRecoveredIdentity(
            startDate: oldStart,
            stableSessionID: realSessionID
        )
        XCTAssertEqual(rebound.sessionID, identityBeforeBind.sessionID)
        XCTAssertEqual(rebound.healthKitSessionID, realSessionID)
        XCTAssertEqual(rebound.sessionToken, identityBeforeBind.sessionToken)
        XCTAssertEqual(
            rebound.transportGenerationID,
            identityBeforeBind.transportGenerationID
        )
        XCTAssertEqual(
            rebound.sequenceHighWatermark,
            identityBeforeBind.sequenceHighWatermark
        )
        XCTAssertEqual(rebound.finishRequest, identityBeforeBind.finishRequest)
        XCTAssertEqual(
            WatchWorkoutRecoveryStore(
                persistence: cleanupPersistence
            ).recoveredIdentity,
            rebound
        )
    }

    func testRecoveredSaveProductionCallerRejectsStaleContextAndRetriesExactlyOnce() async throws {
        for callbackState in [HKWorkoutSessionState.stopped, .ended] {
            let healthStore = HKHealthStore()
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .cycling
            configuration.locationType = .outdoor
            let workoutSession = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let workoutBuilder = workoutSession.associatedWorkoutBuilder()
            let recoveryStore = WatchWorkoutRecoveryStore(
                persistence: ToggleRecoveryPersistence()
            )
            let identity = try recoveryStore.begin(startDate: Date())
            try recoveryStore.markFinishing(
                disposition: .save,
                requestedAt: identity.startDate.addingTimeInterval(30)
            )
            var finalizedModes: [WorkoutSaveFinalizationMode?] = []
            let suspendedQuery = AsyncRecoveredSaveResolutionProbe()
            let manager = WatchWorkoutManager(
                healthStore: healthStore,
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: recoveryStore,
                recoveredSaveRuntimeAdapter: WatchRecoveredSaveRuntimeAdapter(
                    session: workoutSession,
                    builder: workoutBuilder,
                    sessionState: { callbackState }
                ),
                recoveredSaveResolver: { _, _ in
                    await suspendedQuery.run()
                },
                finalizationClaimObserver: { finalizedModes.append($0) },
                initializeOnLaunch: false
            )
            XCTAssertTrue(
                manager.restoreDetachedFinalizationLifecycle(
                    from: try XCTUnwrap(recoveryStore.recoveredIdentity)
                )
            )

            let queryTask = Task { @MainActor in
                await manager.resumeRecoveredStoppedSaveFinalization()
            }
            try await waitUntil { suspendedQuery.callCount == 1 }

            manager.handleSessionReadyForFinalization(
                at: identity.startDate.addingTimeInterval(30)
            )
            XCTAssertTrue(
                finalizedModes.isEmpty,
                "\(callbackState) callback must not claim finalization while query is suspended"
            )

            try recoveryStore.clear()
            suspendedQuery.complete(
                RecoveredSaveResolution(
                    action: .finalize(.alreadySaved),
                    workout: nil
                )
            )
            await queryTask.value
            XCTAssertTrue(finalizedModes.isEmpty)
            XCTAssertEqual(manager.finishRequestError, .reconciliationFailed)

            manager.handleSessionReadyForFinalization(
                at: identity.startDate.addingTimeInterval(31)
            )
            XCTAssertTrue(
                finalizedModes.isEmpty,
                "a callback after stale reconciliation must remain blocked"
            )

            let retryIdentity = try recoveryStore.begin(
                startDate: identity.startDate
            )
            try recoveryStore.markFinishing(
                disposition: .save,
                requestedAt: identity.startDate.addingTimeInterval(32)
            )
            XCTAssertTrue(
                manager.restoreDetachedFinalizationLifecycle(
                    from: try XCTUnwrap(recoveryStore.recoveredIdentity)
                )
            )
            XCTAssertNotEqual(retryIdentity.sessionID, identity.sessionID)

            let retryTask = Task { @MainActor in
                await manager.resumeRecoveredStoppedSaveFinalization()
            }
            try await waitUntil { suspendedQuery.callCount == 2 }
            manager.handleSessionReadyForFinalization(
                at: identity.startDate.addingTimeInterval(33)
            )
            XCTAssertTrue(finalizedModes.isEmpty)

            suspendedQuery.complete(
                RecoveredSaveResolution(
                    action: .finalize(.alreadySaved),
                    workout: nil
                )
            )
            await retryTask.value
            XCTAssertEqual(finalizedModes, [.alreadySaved])

            manager.handleSessionReadyForFinalization(
                at: identity.startDate.addingTimeInterval(34)
            )
            XCTAssertEqual(
                finalizedModes,
                [.alreadySaved],
                "\(callbackState) must not trigger a second finalization claim"
            )
        }
    }

    func testWorkoutSetupRequiresCollectionAndStableIdentityMetadata() {
        var progress = WatchWorkoutSetupProgress()

        XCTAssertFalse(progress.collectionStarted)
        XCTAssertFalse(progress.identityMetadataAttached)
        XCTAssertFalse(progress.canFinalize)

        progress.markIdentityMetadataAttached()
        XCTAssertFalse(progress.identityMetadataAttached)
        XCTAssertFalse(progress.canFinalize)

        progress.markCollectionStarted()
        XCTAssertTrue(progress.collectionStarted)
        XCTAssertFalse(progress.canFinalize)

        progress.markIdentityMetadataAttached()
        XCTAssertTrue(progress.identityMetadataAttached)
        XCTAssertTrue(progress.canFinalize)
    }

    func testRecorderRetainsRecoveredRouteBuilderButDiscardsNewBuilderOnInsertFailure() async {
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_900)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 3,
            timestamp: startDate.addingTimeInterval(1)
        )

        let recoveredBuilder = FailingRouteBuilder()
        let recoveredRecorder = WatchRouteRecorder()
        recoveredRecorder.begin(
            routeBuilder: recoveredBuilder,
            startDate: startDate,
            mayContainExistingRouteData: true,
            onLocationUpdate: {}
        )
        recoveredRecorder.enqueueRouteLocations([location])
        let recoveredRoute = await recoveredRecorder.prepareForWorkoutFinalization()

        XCTAssertTrue(recoveredRecorder.routeSavingFailed)
        XCTAssertEqual(recoveredBuilder.insertCallCount, 1)
        XCTAssertEqual(recoveredBuilder.discardCallCount, 0)
        XCTAssertEqual(recoveredRoute.routeStatus, .unknown)

        let newBuilder = FailingRouteBuilder()
        let newRecorder = WatchRouteRecorder()
        newRecorder.begin(
            routeBuilder: newBuilder,
            startDate: startDate,
            onLocationUpdate: {}
        )
        newRecorder.enqueueRouteLocations([location])
        let newRoute = await newRecorder.prepareForWorkoutFinalization()

        XCTAssertTrue(newRecorder.routeSavingFailed)
        XCTAssertEqual(newBuilder.insertCallCount, 1)
        XCTAssertEqual(newBuilder.discardCallCount, 1)
        XCTAssertEqual(newRoute.routeStatus, .unavailable)
    }

    func testRecorderRetainsRecoveredRouteBuilderButDiscardsNewBuilderOnQueueOverflow() async {
        let startDate = Date(timeIntervalSinceReferenceDate: 800_036_950)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 3,
            timestamp: startDate.addingTimeInterval(1)
        )
        let overflowingLocations = Array(
            repeating: location,
            count: WorkoutRouteQueuePolicy.maximumPendingPointCount + 1
        )

        let recoveredBuilder = FailingRouteBuilder()
        let recoveredRecorder = WatchRouteRecorder()
        recoveredRecorder.begin(
            routeBuilder: recoveredBuilder,
            startDate: startDate,
            mayContainExistingRouteData: true,
            onLocationUpdate: {}
        )
        recoveredRecorder.enqueueRouteLocations(overflowingLocations)
        let recoveredRoute = await recoveredRecorder.prepareForWorkoutFinalization()

        XCTAssertTrue(recoveredRecorder.routeSavingFailed)
        XCTAssertEqual(recoveredBuilder.insertCallCount, 0)
        XCTAssertEqual(recoveredBuilder.discardCallCount, 0)
        XCTAssertEqual(recoveredRoute.routeStatus, .unknown)

        let newBuilder = FailingRouteBuilder()
        let newRecorder = WatchRouteRecorder()
        newRecorder.begin(
            routeBuilder: newBuilder,
            startDate: startDate,
            onLocationUpdate: {}
        )
        newRecorder.enqueueRouteLocations(overflowingLocations)
        let newRoute = await newRecorder.prepareForWorkoutFinalization()

        XCTAssertTrue(newRecorder.routeSavingFailed)
        XCTAssertEqual(newBuilder.insertCallCount, 0)
        XCTAssertEqual(newBuilder.discardCallCount, 1)
        XCTAssertEqual(newRoute.routeStatus, .unavailable)
    }

    func testQuickEndAndSaveDuringMetadataFailureRetainsCollectedWorkoutForRetry() async throws {
        let metadata = AsyncThrowingVoidProbe()
        var lifecycleState = WorkoutSessionStateV1.starting
        var finishDisposition: WorkoutFinishDisposition?

        let outcomeTask = Task { @MainActor in
            await WatchWorkoutIdentityMetadataCoordinator.attach(
                collectionStarted: true,
                attachMetadata: { try await metadata.run() },
                lifecycleState: { lifecycleState },
                finishDisposition: { finishDisposition }
            )
        }

        try await waitUntil { metadata.callCount == 1 }
        lifecycleState = .ending
        finishDisposition = .save
        metadata.fail()

        switch await outcomeTask.value {
        case .retainForFinishRetry:
            break
        case .ready, .failStart:
            XCTFail("An explicit Save must retain the collected workout for metadata retry")
        }
    }

    func testManagerPreservesDurableQuickEndSaveOnIdentityMetadataFailure() async throws {
        enum ExpectedFailure: Error { case metadata }

        let recovery = RecoveryProbe()
        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: ToggleRecoveryPersistence()
        )
        let identity = try recoveryStore.begin(
            startDate: Date(timeIntervalSinceReferenceDate: 800_037_100)
        )
        let requestedAt = identity.startDate.addingTimeInterval(1)
        try recoveryStore.markFinishing(
            disposition: .save,
            requestedAt: requestedAt
        )
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering && manager.state == .ending }

        XCTAssertTrue(
            manager.retainCollectedFinishForIdentityMetadataRetry(
                ExpectedFailure.metadata
            )
        )
        XCTAssertEqual(manager.state, .ending)
        XCTAssertEqual(manager.finishRequestError, .identityMetadataFailed)
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.finishRequest,
            WatchWorkoutRecoveryStore.FinishRequest(
                disposition: .save,
                requestedAt: requestedAt
            )
        )
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.sessionID,
            identity.sessionID
        )
    }

    func testMetadataFailureRetainsDiscardButFailsOrdinaryStartupClosed() async {
        enum ExpectedFailure: Error { case metadata }

        let discardOutcome = await WatchWorkoutIdentityMetadataCoordinator.attach(
            collectionStarted: true,
            attachMetadata: { throw ExpectedFailure.metadata },
            lifecycleState: { .ending },
            finishDisposition: { .discard }
        )
        if case .retainForFinishRetry = discardOutcome {
            // Expected: even discard waits for stable identity metadata so a
            // genuinely late recovered builder remains discard-only.
        } else {
            XCTFail("An explicit Discard must retain the workout for metadata retry")
        }

        let startupOutcome = await WatchWorkoutIdentityMetadataCoordinator.attach(
            collectionStarted: true,
            attachMetadata: { throw ExpectedFailure.metadata },
            lifecycleState: { .starting },
            finishDisposition: { nil }
        )
        if case .failStart = startupOutcome {
            // Expected: an ordinary unidentifiable startup fails closed.
        } else {
            XCTFail("Ordinary metadata failure must fail startup closed")
        }
    }

    func testFinishFailureRollbackMustPersistBeforeRetry() {
        var isPending = true
        var attempts = 0
        var shouldFail = true

        XCTAssertFalse(
            WatchFinishFailureRollbackCoordinator.persistBeforeRetry(
                isPending: &isPending,
                markFinishFailed: {
                    attempts += 1
                    if shouldFail { throw ToggleRecoveryPersistence.Failure.requested }
                }
            )
        )
        XCTAssertTrue(isPending)
        XCTAssertEqual(attempts, 1)

        shouldFail = false
        XCTAssertTrue(
            WatchFinishFailureRollbackCoordinator.persistBeforeRetry(
                isPending: &isPending,
                markFinishFailed: { attempts += 1 }
            )
        )
        XCTAssertFalse(isPending)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(
            WatchFinishFailureRollbackCoordinator.persistBeforeRetry(
                isPending: &isPending,
                markFinishFailed: { attempts += 1 }
            )
        )
        XCTAssertEqual(attempts, 2, "a persisted rollback must not repeat")
    }

    func testPendingFinishRollbackBlocksCallbacksUntilExplicitRetryPersistsIt() async throws {
        for callbackState in [HKWorkoutSessionState.stopped, .ended] {
            let persistence = ToggleRecoveryPersistence()
            let recoveryStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            let startDate = Date(timeIntervalSinceReferenceDate: 800_037_100)
            let identity = try recoveryStore.begin(startDate: startDate)
            try recoveryStore.markFinishing(
                disposition: .save,
                requestedAt: startDate.addingTimeInterval(30)
            )
            try recoveryStore.markCollectionEnded()
            try recoveryStore.markFinishAttempted()

            let healthStore = HKHealthStore()
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .cycling
            configuration.locationType = .outdoor
            let workoutSession = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let workoutBuilder = workoutSession.associatedWorkoutBuilder()
            var finalizedModes: [WorkoutSaveFinalizationMode?] = []
            let manager = WatchWorkoutManager(
                healthStore: healthStore,
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: recoveryStore,
                recoveredSaveRuntimeAdapter: WatchRecoveredSaveRuntimeAdapter(
                    session: workoutSession,
                    builder: workoutBuilder,
                    sessionState: { callbackState }
                ),
                recoveredSaveResolver: { _, _ in
                    RecoveredSaveResolution(
                        action: .finalize(.full),
                        workout: nil
                    )
                },
                initialFinishFailureRollbackPending: true,
                finalizationClaimObserver: { finalizedModes.append($0) },
                initializeOnLaunch: false
            )
            XCTAssertTrue(
                manager.restoreDetachedFinalizationLifecycle(
                    from: try XCTUnwrap(recoveryStore.recoveredIdentity)
                )
            )

            manager.handleSessionReadyForFinalization(
                at: startDate.addingTimeInterval(31)
            )
            XCTAssertTrue(
                finalizedModes.isEmpty,
                "\(callbackState) must not bypass a pending durable rollback"
            )

            let failingSaveCall = persistence.saveCallCount + 1
            persistence.failOnSaveCall = failingSaveCall
            manager.retryFinalization()
            try await waitUntil {
                persistence.saveCallCount >= failingSaveCall
            }
            XCTAssertEqual(manager.finishRequestError, .saveFailed)
            XCTAssertEqual(
                recoveryStore.recoveredIdentity?.finishRequest?.phase,
                .finishAttempted
            )

            manager.handleSessionReadyForFinalization(
                at: startDate.addingTimeInterval(32)
            )
            XCTAssertTrue(finalizedModes.isEmpty)

            persistence.failOnSaveCall = nil
            manager.retryFinalization()
            try await waitUntil { finalizedModes.count == 1 }
            XCTAssertEqual(finalizedModes, [.full])
            XCTAssertNil(manager.finishRequestError)
            XCTAssertEqual(
                recoveryStore.recoveredIdentity?.finishRequest?.phase,
                .collectionEnded,
                "explicit retry must persist the rollback before finalization resumes"
            )

            manager.handleSessionReadyForFinalization(
                at: startDate.addingTimeInterval(33)
            )
            XCTAssertEqual(
                finalizedModes,
                [.full],
                "\(callbackState) must not trigger a second finalization"
            )
            XCTAssertEqual(recoveryStore.recoveredIdentity?.sessionID, identity.sessionID)
        }
    }

    func testRelaunchKeepsFinishAttemptNoMatchCommitUnknownWithoutDuplicateFinalization() async throws {
        let persistence = ToggleRecoveryPersistence()
        let originalStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let startDate = Date(timeIntervalSinceReferenceDate: 800_037_200)
        let originalIdentity = try originalStore.begin(startDate: startDate)
        try originalStore.markFinishing(
            disposition: .save,
            requestedAt: startDate.addingTimeInterval(30)
        )
        try originalStore.markCollectionEnded()
        try originalStore.markFinishAttempted()

        // A fresh store represents process death after the definitive finish
        // callback but before its rollback could be persisted.
        let relaunchedStore = WatchWorkoutRecoveryStore(persistence: persistence)
        XCTAssertEqual(
            relaunchedStore.recoveredIdentity?.sessionID,
            originalIdentity.sessionID
        )

        let healthStore = HKHealthStore()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        let workoutSession = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: configuration
        )
        let workoutBuilder = workoutSession.associatedWorkoutBuilder()
        var lookupCount = 0
        var finalizedModes: [WorkoutSaveFinalizationMode?] = []
        let manager = WatchWorkoutManager(
            healthStore: healthStore,
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: relaunchedStore,
            recoveredSaveRuntimeAdapter: WatchRecoveredSaveRuntimeAdapter(
                session: workoutSession,
                builder: workoutBuilder,
                sessionState: { .stopped },
                externalUUID: { originalIdentity.sessionID.uuidString },
                builderCollectionEnded: { true }
            ),
            savedWorkoutLookup: { _, _ in
                lookupCount += 1
                return nil
            },
            finalizationClaimObserver: { finalizedModes.append($0) },
            initializeOnLaunch: false
        )
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(
                from: try XCTUnwrap(relaunchedStore.recoveredIdentity)
            )
        )

        await manager.resumeRecoveredStoppedSaveFinalization()
        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(manager.finishRequestError, .reconciliationFailed)
        XCTAssertTrue(finalizedModes.isEmpty)
        XCTAssertEqual(
            relaunchedStore.recoveredIdentity?.finishRequest?.phase,
            .finishAttempted
        )

        manager.handleSessionReadyForFinalization(
            at: startDate.addingTimeInterval(31)
        )
        XCTAssertTrue(finalizedModes.isEmpty)

        manager.retryFinalization()
        try await waitUntil { lookupCount == 2 }
        XCTAssertEqual(lookupCount, 2)
        XCTAssertTrue(
            finalizedModes.isEmpty,
            "repeated query misses must never retry HealthKit finishWorkout"
        )
        XCTAssertEqual(
            relaunchedStore.recoveredIdentity?.finishRequest?.phase,
            .finishAttempted
        )

        manager.handleSessionReadyForFinalization(
            at: startDate.addingTimeInterval(32)
        )
        XCTAssertTrue(finalizedModes.isEmpty)
    }

    func testAdoptedProductionEnvelopeReconnectsWhenSequenceOneWasMissed() async throws {
        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: ToggleRecoveryPersistence()
        )
        let startDate = Date().addingTimeInterval(-120)
        let stableSessionID = UUID()
        let adopted = try recoveryStore.useRecoveredIdentity(
            startDate: startDate,
            stableSessionID: stableSessionID
        )
        let recoveredGeneration = try XCTUnwrap(adopted.transportGenerationID)
        try recoveryStore.markFinishing(
            disposition: .save,
            requestedAt: startDate.addingTimeInterval(90)
        )
        try recoveryStore.markCollectionEnded()
        try recoveryStore.markFinishAttempted()

        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            savedWorkoutLookup: { _, _ in nil },
            initializeOnLaunch: false
        )
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(
                from: try XCTUnwrap(recoveryStore.recoveredIdentity)
            )
        )

        await manager.reconcileDetachedSave()
        XCTAssertEqual(manager.latestEnvelope?.sequence, 1)
        await manager.reconcileDetachedSave()
        let firstObservedAfterReconnect = try XCTUnwrap(manager.latestEnvelope)
        XCTAssertEqual(firstObservedAfterReconnect.sequence, 2)
        XCTAssertEqual(
            firstObservedAfterReconnect.transportGenerationID,
            recoveredGeneration
        )

        let originalGeneration = UUID()
        // Deliberately model the 1-in-65,535 random-token collision. The
        // explicit generation UUID, not token inequality, authorizes reset.
        let oldToken = adopted.sessionToken
        let oldEnvelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: stableSessionID,
            sessionToken: oldToken,
            transportGenerationID: originalGeneration,
            sequence: 9,
            capturedAt: startDate.addingTimeInterval(10),
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: startDate
            )
        )
        var receiver = WorkoutEnvelopeSequenceGate()
        XCTAssertTrue(try receiver.ingest(oldEnvelope))
        XCTAssertTrue(
            try receiver.ingest(firstObservedAfterReconnect),
            "an explicit unseen generation must reconnect even when sequence one was missed"
        )
        XCTAssertEqual(
            receiver.transportGenerationBySession[stableSessionID],
            recoveredGeneration
        )
        XCTAssertFalse(
            try receiver.ingest(
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: stableSessionID,
                    sessionToken: oldToken,
                    transportGenerationID: originalGeneration,
                    sequence: 10,
                    capturedAt: Date().addingTimeInterval(1),
                    snapshot: WorkoutSnapshotV1(
                        state: .ending,
                        startDate: startDate
                    )
                )
            ),
            "a retired generation must stay rejected even with a newer capture time"
        )
    }

    func testDetachedSaveReconciliationIsSingleFlightAndRejectsReplacedIdentity() async throws {
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let startDate = Date(timeIntervalSinceReferenceDate: 800_037_300)
        let originalIdentity = try recoveryStore.begin(startDate: startDate)
        try recoveryStore.markFinishing(
            disposition: .save,
            requestedAt: startDate.addingTimeInterval(30)
        )
        try recoveryStore.markCollectionEnded()
        try recoveryStore.markFinishAttempted()

        let lookup = AsyncSavedWorkoutLookupProbe()
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            savedWorkoutLookup: { _, _ in await lookup.run() },
            initializeOnLaunch: false
        )
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(
                from: try XCTUnwrap(recoveryStore.recoveredIdentity)
            )
        )

        let firstQuery = Task { @MainActor in
            await manager.reconcileDetachedSave()
        }
        try await waitUntil { lookup.callCount == 1 }
        await manager.reconcileDetachedSave()
        XCTAssertEqual(lookup.callCount, 1, "detached lookup must be single-flight")

        try recoveryStore.clear()
        let replacementIdentity = try recoveryStore.begin(startDate: startDate)
        try recoveryStore.markFinishing(
            disposition: .save,
            requestedAt: startDate.addingTimeInterval(31)
        )
        try recoveryStore.markCollectionEnded()
        try recoveryStore.markFinishAttempted()
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(
                from: try XCTUnwrap(recoveryStore.recoveredIdentity)
            )
        )

        lookup.complete(nil)
        await firstQuery.value
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.sessionID,
            replacementIdentity.sessionID
        )
        XCTAssertNotEqual(replacementIdentity.sessionID, originalIdentity.sessionID)
        XCTAssertNil(manager.summary)
        XCTAssertNil(
            recoveryStore.terminalTombstone(
                externalUUID: originalIdentity.sessionID.uuidString
            )
        )

        let validRetry = Task { @MainActor in
            await manager.reconcileDetachedSave()
        }
        try await waitUntil { lookup.callCount == 2 }
        lookup.complete(nil)
        await validRetry.value
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.finishRequest?.phase,
            .finishAttempted,
            "the released gate must permit a current-context retry without resaving"
        )
        XCTAssertEqual(manager.finishRequestError, .reconciliationFailed)
    }

    func testManagerPublishesAttachedTerminalStateBeforeSaveOrDiscardArchive() throws {
        for disposition in [WorkoutFinishDisposition.save, .discard] {
            let persistence = ToggleRecoveryPersistence()
            let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
            let identity = try recoveryStore.begin(startDate: Date())
            let endedAt = identity.startDate.addingTimeInterval(60)
            try recoveryStore.markFinishing(
                disposition: disposition,
                requestedAt: endedAt
            )
            if disposition == .save {
                try recoveryStore.markCollectionEnded()
                try recoveryStore.markFinishAttempted()
                try recoveryStore.markWorkoutSaved()
            }
            let manager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: recoveryStore,
                initializeOnLaunch: false
            )
            XCTAssertTrue(
                manager.restoreDetachedFinalizationLifecycle(
                    from: try XCTUnwrap(recoveryStore.recoveredIdentity)
                )
            )

            var stateObservedDuringArchive: WorkoutSessionStateV1?
            var snapshotObservedDuringArchive: WorkoutSessionStateV1?
            var envelopeObservedDuringArchive: WorkoutSessionStateV1?
            persistence.onSave = {
                stateObservedDuringArchive = manager.state
                snapshotObservedDuringArchive = manager.snapshot.state
                envelopeObservedDuringArchive = manager.latestEnvelope?.snapshot?.state
            }
            let summary = WatchWorkoutSummary(
                outcome: disposition == .save ? .saved : .discarded,
                endedAt: endedAt,
                duration: 60,
                distanceMeters: nil,
                activeEnergyKilocalories: nil,
                averageHeartRate: nil,
                routeStatus: .unavailable
            )

            if disposition == .save {
                manager.completeConfirmedSave(
                    summary: summary,
                    savedAt: endedAt
                )
            } else {
                manager.completeConfirmedDiscard(
                    summary: summary,
                    discardedAt: endedAt
                )
            }

            XCTAssertEqual(stateObservedDuringArchive, .ended)
            XCTAssertEqual(snapshotObservedDuringArchive, .ended)
            XCTAssertEqual(envelopeObservedDuringArchive, .ended)
            XCTAssertEqual(manager.state, .ended)
            XCTAssertNil(recoveryStore.recoveredIdentity)
            XCTAssertEqual(
                recoveryStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                )?.disposition,
                disposition
            )
        }
    }

    func testAttachedTerminalArchiveFailureRetainsProofUntilRetry() throws {
        for disposition in [WorkoutFinishDisposition.save, .discard] {
            let persistence = ToggleRecoveryPersistence()
            let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
            let identity = try recoveryStore.begin(startDate: Date())
            let endedAt = identity.startDate.addingTimeInterval(30)
            try recoveryStore.markFinishing(
                disposition: disposition,
                requestedAt: endedAt
            )
            if disposition == .save {
                try recoveryStore.markCollectionEnded()
                try recoveryStore.markFinishAttempted()
                try recoveryStore.markWorkoutSaved()
            }
            let manager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: recoveryStore,
                initializeOnLaunch: false
            )
            XCTAssertTrue(
                manager.restoreDetachedFinalizationLifecycle(
                    from: try XCTUnwrap(recoveryStore.recoveredIdentity)
                )
            )
            let summary = WatchWorkoutSummary(
                outcome: disposition == .save ? .saved : .discarded,
                endedAt: endedAt,
                duration: 30,
                distanceMeters: nil,
                activeEnergyKilocalories: nil,
                averageHeartRate: nil,
                routeStatus: .unavailable
            )

            // Terminal publication reserves one sequence lease first; fail
            // the following persistence write, which is the archive itself.
            persistence.failOnSaveCall = persistence.saveCallCount + 2
            if disposition == .save {
                manager.completeConfirmedSave(summary: summary, savedAt: endedAt)
            } else {
                manager.completeConfirmedDiscard(
                    summary: summary,
                    discardedAt: endedAt
                )
            }

            XCTAssertEqual(manager.snapshot.state, .ended)
            XCTAssertEqual(manager.latestEnvelope?.snapshot?.state, .ended)
            XCTAssertTrue(manager.isTerminalArchivePending)
            XCTAssertEqual(
                recoveryStore.recoveredIdentity?.sessionID,
                identity.sessionID
            )

            persistence.failOnSaveCall = nil
            manager.retryDetachedSessionCleanup()
            XCTAssertFalse(manager.isTerminalArchivePending)
            XCTAssertNil(recoveryStore.recoveredIdentity)
            XCTAssertEqual(
                recoveryStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                )?.disposition,
                disposition
            )
        }
    }

    func testTerminalEnvelopeFailureBlocksArchiveUntilPublicationRetry() throws {
        for disposition in [WorkoutFinishDisposition.save, .discard] {
            let persistence = ToggleRecoveryPersistence()
            let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
            let identity = try recoveryStore.begin(startDate: Date())
            let endedAt = identity.startDate.addingTimeInterval(40)
            try recoveryStore.markFinishing(
                disposition: disposition,
                requestedAt: endedAt
            )
            if disposition == .save {
                try recoveryStore.markCollectionEnded()
                try recoveryStore.markFinishAttempted()
                try recoveryStore.markWorkoutSaved()
            }
            let manager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: recoveryStore,
                initializeOnLaunch: false
            )
            XCTAssertTrue(
                manager.restoreDetachedFinalizationLifecycle(
                    from: try XCTUnwrap(recoveryStore.recoveredIdentity)
                )
            )
            let summary = WatchWorkoutSummary(
                outcome: disposition == .save ? .saved : .discarded,
                endedAt: endedAt,
                duration: 40,
                distanceMeters: nil,
                activeEnergyKilocalories: nil,
                averageHeartRate: nil,
                routeStatus: .unavailable
            )

            // Fail sequence-lease persistence, before an ended envelope can
            // exist. The terminal identity must not be archived yet.
            persistence.failOnSaveCall = persistence.saveCallCount + 1
            if disposition == .save {
                manager.completeConfirmedSave(summary: summary, savedAt: endedAt)
            } else {
                manager.completeConfirmedDiscard(
                    summary: summary,
                    discardedAt: endedAt
                )
            }

            XCTAssertTrue(manager.isTerminalPublicationPending)
            XCTAssertFalse(manager.isTerminalArchivePending)
            XCTAssertEqual(manager.snapshot.state, .ended)
            XCTAssertNotEqual(manager.latestEnvelope?.snapshot?.state, .ended)
            XCTAssertEqual(
                recoveryStore.recoveredIdentity?.sessionID,
                identity.sessionID
            )
            XCTAssertNil(
                recoveryStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                )
            )

            persistence.failOnSaveCall = nil
            manager.retryDetachedSessionCleanup()
            XCTAssertFalse(manager.isTerminalPublicationPending)
            XCTAssertFalse(manager.isTerminalArchivePending)
            XCTAssertEqual(manager.latestEnvelope?.snapshot?.state, .ended)
            XCTAssertNil(recoveryStore.recoveredIdentity)
            XCTAssertEqual(
                recoveryStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                )?.disposition,
                disposition
            )
        }
    }

    func testTerminalPublicationRetryPreservesConfirmedBuilderElapsedSnapshot() throws {
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let identity = try recoveryStore.begin(startDate: Date())
        let endedAt = identity.startDate.addingTimeInterval(123)
        try recoveryStore.markFinishing(
            disposition: .save,
            requestedAt: endedAt
        )
        try recoveryStore.markCollectionEnded()
        try recoveryStore.markFinishAttempted()
        try recoveryStore.markWorkoutSaved()

        let healthStore = HKHealthStore()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        let workoutSession = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: configuration
        )
        let workoutBuilder = workoutSession.associatedWorkoutBuilder()
        let manager = WatchWorkoutManager(
            healthStore: healthStore,
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoveredSaveRuntimeAdapter: WatchRecoveredSaveRuntimeAdapter(
                session: workoutSession,
                builder: workoutBuilder,
                sessionState: { .stopped }
            ),
            builderElapsedTime: { builder in
                builder == nil ? .nan : 123
            },
            initializeOnLaunch: false
        )
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(
                from: try XCTUnwrap(recoveryStore.recoveredIdentity)
            )
        )
        let summary = WatchWorkoutSummary(
            outcome: .saved,
            endedAt: endedAt,
            duration: 123,
            distanceMeters: nil,
            activeEnergyKilocalories: nil,
            averageHeartRate: nil,
            routeStatus: .unknown
        )

        persistence.failOnSaveCall = persistence.saveCallCount + 1
        manager.completeConfirmedSave(summary: summary, savedAt: endedAt)
        let confirmedSnapshot = manager.snapshot
        XCTAssertTrue(manager.isTerminalPublicationPending)
        XCTAssertEqual(confirmedSnapshot.elapsedTime?.value, 123)
        XCTAssertTrue(confirmedSnapshot.availability.contains(.elapsedTime))

        persistence.failOnSaveCall = nil
        manager.retryDetachedSessionCleanup()
        XCTAssertFalse(manager.isTerminalPublicationPending)
        XCTAssertEqual(manager.latestEnvelope?.snapshot, confirmedSnapshot)
        XCTAssertEqual(manager.latestEnvelope?.snapshot?.elapsedTime?.value, 123)
        XCTAssertNil(recoveryStore.recoveredIdentity)
    }

    func testNoSessionRecoveryRetainsRichConfirmedSummaryDuringPublicationRetry() async throws {
        let recovery = RecoveryProbe()
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let identity = try recoveryStore.begin(startDate: Date())
        let endedAt = identity.startDate.addingTimeInterval(75)
        try recoveryStore.markFinishing(
            disposition: .save,
            requestedAt: endedAt
        )
        try recoveryStore.markCollectionEnded()
        try recoveryStore.markFinishAttempted()
        try recoveryStore.markWorkoutSaved()
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            initializeOnLaunch: false
        )
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(
                from: try XCTUnwrap(recoveryStore.recoveredIdentity)
            )
        )
        let richSummary = WatchWorkoutSummary(
            outcome: .saved,
            endedAt: endedAt,
            duration: 75,
            distanceMeters: 1_234,
            activeEnergyKilocalories: 88,
            averageHeartRate: 142,
            routeStatus: .present
        )

        persistence.failsSave = true
        manager.completeConfirmedSave(summary: richSummary, savedAt: endedAt)
        XCTAssertTrue(manager.isTerminalPublicationPending)
        XCTAssertEqual(manager.summary, richSummary)

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering }

        XCTAssertTrue(manager.isTerminalPublicationPending)
        XCTAssertEqual(
            manager.summary,
            richSummary,
            "queued no-session recovery must not rebuild a lossy detached summary"
        )

        persistence.failsSave = false
        manager.retryDetachedSessionCleanup()
        XCTAssertFalse(manager.isTerminalPublicationPending)
        XCTAssertNil(recoveryStore.recoveredIdentity)
        XCTAssertEqual(manager.summary, richSummary)
    }

    func testOrdinaryAttachedDiscardTombstoneMakesLateBuilderDiscardOnly() throws {
        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: ToggleRecoveryPersistence()
        )
        let identity = try recoveryStore.begin(startDate: Date())
        let endedAt = identity.startDate.addingTimeInterval(20)
        try recoveryStore.markFinishing(
            disposition: .discard,
            requestedAt: endedAt
        )
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            initializeOnLaunch: false
        )
        XCTAssertTrue(
            manager.restoreDetachedFinalizationLifecycle(
                from: try XCTUnwrap(recoveryStore.recoveredIdentity)
            )
        )
        manager.completeConfirmedDiscard(
            summary: WatchWorkoutSummary(
                outcome: .discarded,
                endedAt: endedAt,
                duration: 20,
                distanceMeters: nil,
                activeEnergyKilocalories: nil,
                averageHeartRate: nil,
                routeStatus: .unavailable
            ),
            discardedAt: endedAt
        )
        let tombstone = try XCTUnwrap(
            recoveryStore.terminalTombstone(
                externalUUID: identity.sessionID.uuidString
            )
        )
        var actions: [String] = []

        manager.completeTerminalTombstoneCleanup(
            sessionID: tombstone.sessionID,
            disposition: tombstone.disposition,
            discardWorkout: { actions.append("discard-builder") },
            endSession: { actions.append("end-session") },
            releaseSession: { actions.append("release-session") }
        )

        XCTAssertEqual(
            actions,
            ["discard-builder", "end-session", "release-session"]
        )
        XCTAssertNil(
            recoveryStore.terminalTombstone(
                externalUUID: identity.sessionID.uuidString
            )
        )
    }

    func testRetryFinalizationRetriesMetadataBeforeResumingAttachedFinish() async throws {
        enum ExpectedFailure: Error { case metadata }

        for disposition in [WorkoutFinishDisposition.save, .discard] {
            let recoveryStore = WatchWorkoutRecoveryStore(
                persistence: ToggleRecoveryPersistence()
            )
            let identity = try recoveryStore.begin(startDate: Date())
            try recoveryStore.markFinishing(
                disposition: disposition,
                requestedAt: identity.startDate.addingTimeInterval(1)
            )
            var actions: [String] = []
            var metadataAttemptCount = 0
            var shouldFail = true
            let manager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: recoveryStore,
                identityMetadataRetryAdapter: WatchWorkoutIdentityMetadataRetryAdapter(
                    attachMetadata: {
                        metadataAttemptCount += 1
                        actions.append("attach-metadata-\(metadataAttemptCount)")
                        if shouldFail { throw ExpectedFailure.metadata }
                    },
                    isContextCurrent: { true },
                    resumeFinalization: { actions.append("resume-finalization") }
                ),
                initializeOnLaunch: false
            )
            XCTAssertTrue(
                manager.restoreDetachedFinalizationLifecycle(
                    from: try XCTUnwrap(recoveryStore.recoveredIdentity)
                )
            )
            XCTAssertTrue(
                manager.retainCollectedFinishForIdentityMetadataRetry(
                    ExpectedFailure.metadata
                )
            )

            manager.retryFinalization()
            try await waitUntil {
                metadataAttemptCount == 1
                    && manager.finishRequestError == .identityMetadataFailed
            }
            XCTAssertEqual(actions, ["attach-metadata-1"])
            XCTAssertEqual(manager.state, .ending)
            XCTAssertEqual(
                recoveryStore.recoveredIdentity?.finishRequest?.disposition,
                disposition
            )

            shouldFail = false
            manager.retryFinalization()
            try await waitUntil { actions.last == "resume-finalization" }
            XCTAssertEqual(
                actions,
                ["attach-metadata-1", "attach-metadata-2", "resume-finalization"]
            )
            XCTAssertNil(manager.finishRequestError)
            XCTAssertEqual(manager.state, .ending)
            XCTAssertEqual(
                recoveryStore.recoveredIdentity?.sessionID,
                identity.sessionID
            )
        }
    }

    func testQueryConfirmedSaveAdvancesEarlyPhasesBeforeArchive() throws {
        for collectionAlreadyEnded in [false, true] {
            let persistence = ToggleRecoveryPersistence()
            let recoveryStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            let identity = try recoveryStore.begin(startDate: Date())
            try recoveryStore.markFinishing(
                disposition: .save,
                requestedAt: identity.startDate.addingTimeInterval(30)
            )
            if collectionAlreadyEnded {
                try recoveryStore.markCollectionEnded()
            }
            let manager = WatchWorkoutManager(
                healthStore: HKHealthStore(),
                routeRecorder: WatchRouteRecorder(),
                recoveryStore: recoveryStore,
                initializeOnLaunch: false
            )

            persistence.failsSave = true
            XCTAssertFalse(
                manager.persistQueryConfirmedSaveBeforeTerminalization(true)
            )
            XCTAssertEqual(
                recoveryStore.recoveredIdentity?.finishRequest?.phase,
                collectionAlreadyEnded ? .collectionEnded : .requested
            )

            persistence.failsSave = false
            XCTAssertTrue(
                manager.persistQueryConfirmedSaveBeforeTerminalization(true)
            )
            XCTAssertEqual(
                recoveryStore.recoveredIdentity?.finishRequest?.phase,
                .workoutSaved
            )
            let tombstone = try recoveryStore.archiveConfirmedSavedIdentity()
            XCTAssertEqual(tombstone.sessionID, identity.sessionID)
            XCTAssertEqual(tombstone.disposition, .save)
        }
    }

    func testRecoverySignalDuringAttachedSessionQueuesUntilRelease() {
        var queue = WatchRecoverySignalQueue()

        XCTAssertFalse(queue.recordSignal(hasAttachedSession: true))
        XCTAssertTrue(queue.isPendingWhileSessionAttached)
        XCTAssertEqual(queue.generation, 1)
        XCTAssertTrue(queue.consumeAfterSessionRelease())
        XCTAssertFalse(queue.isPendingWhileSessionAttached)
        XCTAssertFalse(queue.consumeAfterSessionRelease())

        XCTAssertTrue(queue.recordSignal(hasAttachedSession: false))
        XCTAssertEqual(queue.generation, 2)
    }

    func testTerminalTombstoneSessionStatesUseOnlyStopOrComplete() {
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: WatchWorkoutRecoveryStore(
                persistence: ToggleRecoveryPersistence()
            ),
            initializeOnLaunch: false
        )
        let transitionDate = Date(timeIntervalSinceReferenceDate: 800_040_000)
        let stopStates: [HKWorkoutSessionState] = [.running, .paused]
        let completionStates: [HKWorkoutSessionState] = [
            .notStarted,
            .prepared,
            .stopped,
            .ended,
        ]

        for disposition in [WorkoutFinishDisposition.save, .discard] {
            for state in stopStates + completionStates {
                var stoppedAt: [Date] = []
                var completedDispositions: [WorkoutFinishDisposition] = []
                manager.handleTerminalTombstoneSessionState(
                    state,
                    transitionDate: transitionDate,
                    disposition: disposition,
                    adapter: WatchTerminalSessionCleanupAdapter(
                        stopSession: { stoppedAt.append($0) },
                        completeSession: { completedDispositions.append($0) }
                    )
                )

                if stopStates.contains(state) {
                    XCTAssertEqual(stoppedAt, [transitionDate], "state \(state.rawValue)")
                    XCTAssertTrue(completedDispositions.isEmpty, "state \(state.rawValue)")
                } else {
                    XCTAssertTrue(stoppedAt.isEmpty, "state \(state.rawValue)")
                    XCTAssertEqual(completedDispositions, [disposition], "state \(state.rawValue)")
                }
            }
        }
        // Completion retains the terminal save/discard disposition; no path
        // can turn a discard tombstone into a default save.
    }

    func testTerminalTombstoneCompletionConsumesOnlyMatchAndRetriesCurrentActiveIdentity() async throws {
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let terminalIdentity = try archiveSavedIdentity(in: recoveryStore)
        let activeIdentity = try recoveryStore.begin(
            startDate: Date(timeIntervalSinceReferenceDate: 800_041_000)
        )
        var recoveryCallCount = 0
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: {
                recoveryCallCount += 1
                return (
                    nil,
                    NSError(
                        domain: "WatchWorkoutManagerTests.TerminalRecovery",
                        code: 1
                    )
                )
            },
            initializeOnLaunch: false
        )
        var endCount = 0
        var releaseCount = 0
        var discardCount = 0

        manager.completeTerminalTombstoneCleanup(
            sessionID: terminalIdentity.sessionID,
            disposition: .save,
            discardWorkout: { discardCount += 1 },
            endSession: { endCount += 1 },
            releaseSession: { releaseCount += 1 }
        )

        XCTAssertEqual(discardCount, 0)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertNil(
            recoveryStore.terminalTombstone(
                externalUUID: terminalIdentity.sessionID.uuidString
            )
        )
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.sessionID,
            activeIdentity.sessionID
        )
        try await waitUntil {
            recoveryCallCount == 1 && !manager.isRecovering
        }
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.sessionID,
            activeIdentity.sessionID
        )
    }

    func testTerminalTombstoneRemovalFailureEndsSessionButRetainsProof() throws {
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let terminalIdentity = try archiveSavedIdentity(in: recoveryStore)
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            initializeOnLaunch: false
        )
        persistence.failsClear = true
        var endCount = 0
        var releaseCount = 0
        var discardCount = 0

        manager.completeTerminalTombstoneCleanup(
            sessionID: terminalIdentity.sessionID,
            disposition: .save,
            discardWorkout: { discardCount += 1 },
            endSession: { endCount += 1 },
            releaseSession: { releaseCount += 1 }
        )

        XCTAssertEqual(discardCount, 0)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(
            recoveryStore.terminalTombstone(
                externalUUID: terminalIdentity.sessionID.uuidString
            )?.sessionID,
            terminalIdentity.sessionID
        )
        XCTAssertFalse(manager.isRecovering)
    }

    func testDiscardTombstoneDiscardsLateBuilderBeforeEndingSession() throws {
        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: ToggleRecoveryPersistence()
        )
        let terminalIdentity = try archiveDiscardedIdentity(in: recoveryStore)
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            initializeOnLaunch: false
        )
        var actions: [String] = []

        manager.completeTerminalTombstoneCleanup(
            sessionID: terminalIdentity.sessionID,
            disposition: .discard,
            discardWorkout: { actions.append("discard-builder") },
            endSession: { actions.append("end-session") },
            releaseSession: { actions.append("release-session") }
        )

        XCTAssertEqual(
            actions,
            ["discard-builder", "end-session", "release-session"]
        )
        XCTAssertNil(
            recoveryStore.terminalTombstone(
                externalUUID: terminalIdentity.sessionID.uuidString
            )
        )
    }

    func testRecoveryRetryIsSingleFlight() async throws {
        let recovery = RecoveryProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WatchManagerTests.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: WatchWorkoutRecoveryStore(
                persistence: WorkoutRecoveryFilePersistence(
                    fileURL: directory.appendingPathComponent("active.plist")
                )
            ),
            recoverActiveWorkoutSession: {
                await recovery.run()
            },
            initializeOnLaunch: false
        )

        XCTAssertFalse(manager.isRecovering)
        manager.retrySetup()
        manager.retrySetup()

        try await waitUntil { recovery.callCount == 1 }
        XCTAssertTrue(manager.isRecovering)
        XCTAssertEqual(recovery.callCount, 1)

        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering }
        XCTAssertEqual(recovery.callCount, 1)
    }

    func testActiveRecoveryCallbackRetriesAnInFlightEmptyRecovery() async throws {
        let recovery = RecoveryProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WatchManagerTests.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: WatchWorkoutRecoveryStore(
                persistence: WorkoutRecoveryFilePersistence(
                    fileURL: directory.appendingPathComponent("active.plist")
                )
            ),
            recoverActiveWorkoutSession: {
                await recovery.run()
            },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        manager.handleActiveWorkoutRecovery()
        recovery.completeWithoutSession()

        try await waitUntil { recovery.callCount == 2 }
        XCTAssertTrue(manager.isRecovering)
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering }
        XCTAssertEqual(recovery.callCount, 2)
    }

    func testActiveRecoveryCallbackDuringAuthorizationRefreshPreservesIdentityAndRetries() async throws {
        let recovery = RecoveryProbe()
        let authorizationRefresh = AsyncVoidProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WatchManagerTests.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: WorkoutRecoveryFilePersistence(
                fileURL: directory.appendingPathComponent("active.plist")
            )
        )
        let originalIdentity = try recoveryStore.begin(startDate: Date())
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: {
                await recovery.run()
            },
            refreshAuthorization: {
                await authorizationRefresh.run()
            },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { authorizationRefresh.callCount == 1 }

        manager.handleActiveWorkoutRecovery()
        authorizationRefresh.complete()
        try await waitUntil { recovery.callCount == 2 }
        XCTAssertEqual(recoveryStore.recoveredIdentity, originalIdentity)

        recovery.completeWithoutSession()
        try await waitUntil { authorizationRefresh.callCount == 2 }
        authorizationRefresh.complete()
        try await waitUntil { !manager.isRecovering }
        XCTAssertNil(recoveryStore.recoveredIdentity)
    }

    func testLateRecoveryCallbackCannotEraseCorruptResetProtection() async throws {
        let persistence = ToggleRecoveryPersistence()
        persistence.data = Data([0x00, 0x01, 0x02])
        let startDate = Date(timeIntervalSinceReferenceDate: 800_051_000)
        let endDate = startDate.addingTimeInterval(90)
        let stableSessionID = UUID()
        let corruptStore = WatchWorkoutRecoveryStore(
            persistence: persistence
        )
        try corruptStore.quarantineCorruptState()
        _ = try corruptStore.useRecoveredIdentity(
            startDate: startDate,
            stableSessionID: stableSessionID
        )

        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: persistence
        )
        XCTAssertTrue(recoveryStore.hasCorruptResetPendingIdentity)
        let recovery = RecoveryProbe()
        let authorizationRefresh = AsyncVoidProbe()
        var savedLookupCount = 0
        var saveFinalizationClaims: [WorkoutSaveFinalizationMode?] = []
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            refreshAuthorization: { await authorizationRefresh.run() },
            savedWorkoutLookup: { _, _ in
                savedLookupCount += 1
                return nil
            },
            finalizationClaimObserver: {
                saveFinalizationClaims.append($0)
            },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { authorizationRefresh.callCount == 1 }
        authorizationRefresh.complete()
        try await waitUntil { !manager.isRecovering }
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.sessionID,
            stableSessionID,
            "a nil recovery result must preserve pending corrupt-reset identity for a late watchOS signal"
        )
        XCTAssertTrue(recoveryStore.hasCorruptResetPendingIdentity)

        manager.handleActiveWorkoutRecovery()
        try await waitUntil { recovery.callCount == 2 }
        let terminalProbe = RecoveredIdentityProbe(
            metadata: WatchWorkoutManager.workoutIdentityMetadata(
                sessionID: stableSessionID
            ),
            sessionState: .stopped,
            endDate: endDate
        )
        let lateIdentity = await manager.recoverWorkoutIdentity(
            using: terminalProbe.adapter(startDate: startDate)
        )
        XCTAssertEqual(lateIdentity?.finishRequest?.disposition, .discard)
        recovery.completeWithoutSession()
        try await waitUntil {
            !manager.isRecovering && manager.state == .ending
        }
        XCTAssertEqual(savedLookupCount, 0)
        XCTAssertTrue(saveFinalizationClaims.isEmpty)
        XCTAssertNil(manager.summary)
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.finishRequest?.disposition,
            .discard
        )
        XCTAssertNil(
            recoveryStore.terminalTombstone(
                externalUUID: stableSessionID.uuidString
            )
        )
    }

    func testActiveRecoveryCallbackAfterDetachedRecoveryRetriesAttachment() async throws {
        let recovery = RecoveryProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WatchManagerTests.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: WorkoutRecoveryFilePersistence(
                fileURL: directory.appendingPathComponent("active.plist")
            )
        )
        _ = try recoveryStore.begin(startDate: Date())
        try recoveryStore.markFinishing(disposition: .save, requestedAt: Date())
        try recoveryStore.markCollectionEnded()
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering }
        XCTAssertEqual(manager.state, .ending)
        XCTAssertNotNil(recoveryStore.recoveredIdentity)

        manager.handleActiveWorkoutRecovery()
        try await waitUntil { recovery.callCount == 2 }
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering }
        XCTAssertEqual(recovery.callCount, 2)
        XCTAssertNotNil(recoveryStore.recoveredIdentity)
    }

    func testDetachedDiscardArchivesTombstoneAndReleasesUI() async throws {
        let recovery = RecoveryProbe()
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let identity = try recoveryStore.begin(startDate: Date())
        try recoveryStore.markFinishing(
            disposition: .discard,
            requestedAt: identity.startDate.addingTimeInterval(30)
        )
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering && manager.state == .ended }
        XCTAssertEqual(manager.summary?.outcome, .discarded)
        XCTAssertFalse(manager.isAwaitingDetachedSessionCleanup)
        XCTAssertNil(recoveryStore.recoveredIdentity)
        XCTAssertEqual(
            recoveryStore.terminalTombstone(
                externalUUID: identity.sessionID.uuidString
            )?.disposition,
            .discard
        )

        manager.dismissSummary()
        XCTAssertEqual(manager.state, .idle)
        let nextIdentity = try recoveryStore.begin(startDate: Date())
        XCTAssertNotEqual(nextIdentity.sessionID, identity.sessionID)
        XCTAssertEqual(
            recoveryStore.terminalTombstone(
                externalUUID: identity.sessionID.uuidString
            )?.disposition,
            .discard
        )
    }

    func testActiveRecoveryCallbackDuringDetachedRecoveryRetriesAttachment() async throws {
        let recovery = RecoveryProbe()
        let detachedPause = AsyncVoidProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WatchManagerTests.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: WorkoutRecoveryFilePersistence(
                fileURL: directory.appendingPathComponent("active.plist")
            )
        )
        _ = try recoveryStore.begin(startDate: Date())
        try recoveryStore.markFinishing(disposition: .save, requestedAt: Date())
        try recoveryStore.markCollectionEnded()
        var shouldPauseDetachedRecovery = true
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            pauseDetachedRecovery: {
                guard shouldPauseDetachedRecovery else { return }
                shouldPauseDetachedRecovery = false
                await detachedPause.run()
            },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { detachedPause.callCount == 1 }

        manager.handleActiveWorkoutRecovery()
        detachedPause.complete()
        try await waitUntil { recovery.callCount == 2 }
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering }
        XCTAssertEqual(recovery.callCount, 2)
        XCTAssertNotNil(recoveryStore.recoveredIdentity)
    }

    func testDetachedSavedIdentityArchivesTombstoneAndReleasesUI() async throws {
        let recovery = RecoveryProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WatchManagerTests.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryStore = WatchWorkoutRecoveryStore(
            persistence: WorkoutRecoveryFilePersistence(
                fileURL: directory.appendingPathComponent("active.plist")
            )
        )
        let originalIdentity = try recoveryStore.begin(startDate: Date())
        try recoveryStore.markFinishing(disposition: .save, requestedAt: Date())
        try recoveryStore.markCollectionEnded()
        try recoveryStore.markFinishAttempted()
        try recoveryStore.markWorkoutSaved()
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            initializeOnLaunch: false
        )

        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering && manager.state == .ended }
        XCTAssertFalse(manager.isAwaitingDetachedSessionCleanup)
        XCTAssertNotNil(manager.summary)
        XCTAssertEqual(manager.snapshot.state, .ended)
        XCTAssertEqual(manager.latestEnvelope?.snapshot?.state, .ended)
        XCTAssertNil(recoveryStore.recoveredIdentity)
        XCTAssertEqual(
            recoveryStore.terminalTombstone(
                externalUUID: originalIdentity.sessionID.uuidString
            )?.sessionID,
            originalIdentity.sessionID
        )

        manager.dismissSummary()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.summary)

        let nextIdentity = try recoveryStore.begin(startDate: Date())
        XCTAssertNotEqual(nextIdentity.sessionID, originalIdentity.sessionID)
        XCTAssertEqual(
            recoveryStore.terminalTombstone(
                externalUUID: originalIdentity.sessionID.uuidString
            )?.sessionID,
            originalIdentity.sessionID
        )
        try recoveryStore.removeTerminalTombstone(
            sessionID: originalIdentity.sessionID
        )
        XCTAssertNil(
            recoveryStore.terminalTombstone(
                externalUUID: originalIdentity.sessionID.uuidString
            )
        )
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.sessionID,
            nextIdentity.sessionID
        )
    }

    func testDetachedSavedIdentityBlocksNewRideUntilTombstoneRetrySucceeds() async throws {
        let recovery = RecoveryProbe()
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let originalIdentity = try recoveryStore.begin(startDate: Date())
        try recoveryStore.markFinishing(disposition: .save, requestedAt: Date())
        try recoveryStore.markCollectionEnded()
        try recoveryStore.markFinishAttempted()
        try recoveryStore.markWorkoutSaved()
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            recoverActiveWorkoutSession: { await recovery.run() },
            initializeOnLaunch: false
        )

        // Detached recovery first reserves the ending-envelope sequence;
        // fail the following write, which archives the saved identity.
        persistence.failOnSaveCall = persistence.saveCallCount + 2
        manager.retrySetup()
        try await waitUntil { recovery.callCount == 1 }
        recovery.completeWithoutSession()
        try await waitUntil { !manager.isRecovering && manager.state == .ended }

        XCTAssertTrue(manager.isTerminalArchivePending)
        XCTAssertTrue(manager.isAwaitingDetachedSessionCleanup)
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.sessionID,
            originalIdentity.sessionID
        )
        XCTAssertNil(
            recoveryStore.terminalTombstone(
                externalUUID: originalIdentity.sessionID.uuidString
            )
        )

        persistence.failOnSaveCall = nil
        manager.retryDetachedSessionCleanup()
        XCTAssertFalse(manager.isTerminalArchivePending)
        XCTAssertFalse(manager.isAwaitingDetachedSessionCleanup)
        XCTAssertNil(recoveryStore.recoveredIdentity)
        XCTAssertEqual(
            recoveryStore.terminalTombstone(
                externalUUID: originalIdentity.sessionID.uuidString
            )?.sessionID,
            originalIdentity.sessionID
        )
    }

    func testFinishPersistenceFailureStaysVisibleUntilRetrySucceeds() throws {
        let persistence = ToggleRecoveryPersistence()
        let recoveryStore = WatchWorkoutRecoveryStore(persistence: persistence)
        let startDate = Date(timeIntervalSinceReferenceDate: 800_050_000)
        _ = try recoveryStore.begin(startDate: startDate)
        let manager = WatchWorkoutManager(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: recoveryStore,
            initializeOnLaunch: false
        )
        let requestedAt = startDate.addingTimeInterval(60)

        persistence.failsSave = true
        XCTAssertFalse(
            manager.persistFinishRequest(
                disposition: .discard,
                requestedAt: requestedAt
            )
        )
        XCTAssertEqual(manager.finishRequestError, .persistenceFailed)
        XCTAssertNil(recoveryStore.recoveredIdentity?.finishRequest)

        persistence.failsSave = false
        XCTAssertTrue(
            manager.persistFinishRequest(
                disposition: .discard,
                requestedAt: requestedAt
            )
        )
        XCTAssertNil(manager.finishRequestError)
        XCTAssertEqual(
            recoveryStore.recoveredIdentity?.finishRequest,
            WatchWorkoutRecoveryStore.FinishRequest(
                disposition: .discard,
                requestedAt: requestedAt
            )
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for asynchronous Watch state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func archiveSavedIdentity(
        in recoveryStore: WatchWorkoutRecoveryStore
    ) throws -> WatchWorkoutRecoveryStore.Identity {
        let identity = try recoveryStore.begin(
            startDate: Date(timeIntervalSinceReferenceDate: 800_039_000)
        )
        try recoveryStore.markFinishing(
            disposition: .save,
            requestedAt: identity.startDate.addingTimeInterval(60)
        )
        try recoveryStore.markCollectionEnded()
        try recoveryStore.markFinishAttempted()
        try recoveryStore.markWorkoutSaved()
        _ = try recoveryStore.archiveConfirmedSavedIdentity(
            at: identity.startDate.addingTimeInterval(61)
        )
        return identity
    }

    private func archiveDiscardedIdentity(
        in recoveryStore: WatchWorkoutRecoveryStore
    ) throws -> WatchWorkoutRecoveryStore.Identity {
        let identity = try recoveryStore.begin(
            startDate: Date(timeIntervalSinceReferenceDate: 800_038_000)
        )
        try recoveryStore.markFinishing(
            disposition: .discard,
            requestedAt: identity.startDate.addingTimeInterval(30)
        )
        _ = try recoveryStore.archiveConfirmedDiscardedIdentity(
            at: identity.startDate.addingTimeInterval(31)
        )
        return identity
    }
}

private final class ToggleRecoveryPersistence: WorkoutRecoveryPersistence {
    enum Failure: Error {
        case requested
    }

    var data: Data?
    var failsLoad = false
    var failsSave = false
    var failsClear = false
    var failsQuarantine = false
    var onSave: (() -> Void)?
    private(set) var saveCallCount = 0
    var failOnSaveCall: Int?
    private(set) var quarantinedData: [Data] = []

    func load() throws -> Data? {
        if failsLoad { throw Failure.requested }
        return data
    }

    func save(_ data: Data) throws {
        saveCallCount += 1
        onSave?()
        if failsSave || failOnSaveCall == saveCallCount {
            throw Failure.requested
        }
        self.data = data
    }

    func clear() throws {
        if failsClear { throw Failure.requested }
        data = nil
    }

    func quarantine(_ data: Data) throws {
        if failsQuarantine { throw Failure.requested }
        quarantinedData.append(data)
    }
}

@MainActor
private final class FailingRouteBuilder: WatchWorkoutRouteBuilding {
    enum Failure: Error { case requested }

    private(set) var insertCallCount = 0
    private(set) var discardCallCount = 0

    func insertRouteData(_ locations: [CLLocation]) async throws {
        insertCallCount += 1
        throw Failure.requested
    }

    func discard() {
        discardCallCount += 1
    }
}

@MainActor
private final class RecoveredIdentityProbe {
    var metadata: [String: Any]
    var sessionState: HKWorkoutSessionState
    var endDate: Date?
    var failsAttachment = false
    private(set) var attachCallCount = 0

    init(
        metadata: [String: Any],
        sessionState: HKWorkoutSessionState,
        endDate: Date? = nil
    ) {
        self.metadata = metadata
        self.sessionState = sessionState
        self.endDate = endDate
    }

    func adapter(startDate: Date) -> WatchRecoveredWorkoutIdentityAdapter {
        WatchRecoveredWorkoutIdentityAdapter(
            metadata: { [self] in metadata },
            startDate: startDate,
            sessionState: { [self] in sessionState },
            endDate: { [self] in endDate },
            attachMetadata: { [self] attachedMetadata in
                attachCallCount += 1
                if failsAttachment {
                    throw ToggleRecoveryPersistence.Failure.requested
                }
                metadata.merge(attachedMetadata) { _, new in new }
            }
        )
    }
}

@MainActor
private final class RecoveryProbe {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<(
        session: HKWorkoutSession?,
        error: Error?
    ), Never>?

    func run() async -> (session: HKWorkoutSession?, error: Error?) {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func completeWithoutSession() {
        continuation?.resume(returning: (nil, nil))
        continuation = nil
    }

    func completeWithError() {
        continuation?.resume(
            returning: (nil, ToggleRecoveryPersistence.Failure.requested)
        )
        continuation = nil
    }
}

@MainActor
private final class AsyncVoidProbe {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class AsyncThrowingVoidProbe {
    enum Failure: Error {
        case requested
    }

    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Error>?

    func run() async throws {
        callCount += 1
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func fail() {
        continuation?.resume(throwing: Failure.requested)
        continuation = nil
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class AsyncRecoveredSaveResolutionProbe {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<RecoveredSaveResolution, Never>?

    func run() async -> RecoveredSaveResolution {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(_ resolution: RecoveredSaveResolution) {
        continuation?.resume(returning: resolution)
        continuation = nil
    }
}

@MainActor
private final class AsyncSavedWorkoutLookupProbe {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<HKWorkout?, Never>?

    func run() async -> HKWorkout? {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(_ workout: HKWorkout?) {
        continuation?.resume(returning: workout)
        continuation = nil
    }
}
