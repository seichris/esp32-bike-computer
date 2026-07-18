import Foundation
#if WORKOUT_CONTRACT_HOST
import Darwin
#endif
#if WORKOUT_CONTRACT_XCTEST
import XCTest
#endif

private nonisolated func roundTripWorkoutEnvelope(
    _ envelope: WorkoutEnvelopeV1
) throws -> WorkoutEnvelopeV1 {
    try WorkoutContractCodec.decode(WorkoutContractCodec.encode(envelope))
}

private nonisolated final class ControllableRecoveryPersistence: WorkoutRecoveryPersistence {
    enum Failure: Error {
        case requested
    }

    var data: Data?
    var failsLoad = false
    var failsSave = false
    var failsClear = false

    func load() throws -> Data? {
        if failsLoad { throw Failure.requested }
        return data
    }

    func save(_ data: Data) throws {
        if failsSave { throw Failure.requested }
        self.data = data
    }

    func clear() throws {
        if failsClear { throw Failure.requested }
        data = nil
    }
}

private struct WorkoutContractTestSuite {
    private(set) var failureCount = 0

    mutating func run() async {
        testSnapshotRoundTrip()
        testAllMessageKindsRoundTrip()
        testCompatibleMinorVersionIgnoresUnknownFields()
        testUnsupportedMajorVersionIsRejected()
        testOptionalMetricsRemainUnavailable()
        testInvalidEnvelopeIdentityIsRejected()
        testInvalidNumbersAndCoordinatesAreRejected()
        testMetricUnitsAndAvailabilityMustMatchPayload()
        testActiveSnapshotsRequireTrustworthyStartDates()
        testHeartRateMustBePositiveWithoutRejectingMeaningfulZeroes()
        testSpeedRequiresSource()
        testCyclingDistanceRequiresSource()
        testComponentTimestampsStayWithinWorkoutWindow()
        testHeartRateZonePayloadIsCoherent()
        testAltitudeRequiresVerticalAccuracy()
        testUnknownErrorCodesBecomeSafeGenericCodes()
        testSequenceGateRejectsDuplicatesAndOlderSnapshots()
        testSessionIdentityCannotDrift()
        testSameSessionCanAdvanceToNewTransportGeneration()
        testSameSessionLifecycleRejectsRegressions()
        testBatchPublishesOnlyLatestCoherentSnapshot()
        testBatchSkipsInvalidItemsAndContinues()
        testOlderSessionCannotReplaceNewerActiveSession()
        testActiveSessionReplacesIdlePlaceholderRegardlessOfDeliveryOrder()
        testActiveSessionReplacesFailedAttemptRegardlessOfDeliveryOrder()
        testEndedSessionReplacesOnlyOlderPlaceholders()
        testNewerTerminalSessionReplacesOlderTerminalSession()
        testWatchLifecycleRequiresHealthKitConfirmationAndFinalizesOnce()
        testWorkoutLifecycleFailureAndLateRunningPolicies()
        await testWorkoutFinalizationOrchestratorOrderAndFailures()
        testWorkoutFinishAndRecoveryPolicies()
        testMetricPrecedenceDoesNotCombineOrInventSources()
        testInstantaneousMetricFreshnessAndSpeedFallback()
        testBuilderElapsedTimeUsesHealthKitPauseClock()
        testRoutePointFilteringHonorsWorkoutAndAccuracyBounds()
        testRouteTimestampGateRejectsDelayedPausedBatches()
        testRouteSegmentAndQueueBounds()
        testRouteRecoveryDistanceAndAssociatedFinalizationPolicies()
        testRecoverySequenceLeasesNeverReuseReservedValues()
        testRecoveryStorePersistsIdentityAndLeases()
#if WORKOUT_CONTRACT_HOST
        testRecoveryStoreSurvivesProcessRelaunch()
#endif
        testWorkoutFormattingKeepsUnavailableValuesDistinctFromZero()
    }

    private mutating func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !condition else { return }
        failureCount += 1
        fputs("FAIL: \(message) (\(file):\(line))\n", stderr)
    }

    private mutating func expectThrows(
        _ expected: WorkoutContractError,
        _ message: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            expect(false, "\(message): expected \(expected)")
        } catch let error as WorkoutContractError {
            expect(error == expected, "\(message): got \(error), expected \(expected)")
        } catch {
            expect(false, "\(message): unexpected error \(error)")
        }
    }

    private mutating func testSnapshotRoundTrip() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = WorkoutSnapshotV1(
            state: .running,
            startDate: now.addingTimeInterval(-90),
            elapsedTime: metric(90, .seconds, now),
            currentHeartRate: metric(142, .beatsPerMinute, now, .healthKit),
            averageHeartRate: metric(137, .beatsPerMinute, now, .healthKit),
            activeEnergy: metric(41.2, .kilocalories, now, .healthKit),
            cyclingDistance: metric(734.5, .meters, now, .healthKit),
            currentSpeed: metric(8.4, .metersPerSecond, now, .pairedCyclingSensor),
            cyclingPower: metric(211, .watts, now, .healthKit),
            cyclingCadence: metric(88, .revolutionsPerMinute, now, .healthKit),
            currentHeartRateZone: 3,
            heartRateZoneCount: 5,
            heartRateZoneDurations: WorkoutZoneDurationsV1(
                capturedAt: now,
                secondsByZone: [10, 20, 30, 20, 10]
            ),
            location: WorkoutLocationV1(
                latitude: 1.3521,
                longitude: 103.8198,
                capturedAt: now,
                horizontalAccuracy: 4,
                altitude: 12,
                verticalAccuracy: 6,
                course: 182,
                speed: 8.1
            ),
            availability: [
                .elapsedTime,
                .currentHeartRate,
                .averageHeartRate,
                .activeEnergy,
                .cyclingDistance,
                .currentSpeed,
                .cyclingPower,
                .cyclingCadence,
                .heartRateZone,
                .location,
                .altitude,
            ]
        )
        let envelope = makeEnvelope(sequence: 1, capturedAt: now, snapshot: snapshot)

        do {
            let data = try WorkoutContractCodec.encode(envelope)
            expect(data.starts(with: Data("bplist".utf8)), "contract should use a binary property list")
            expect(try roundTripWorkoutEnvelope(envelope) == envelope, "snapshot should round-trip")
        } catch {
            expect(false, "snapshot round-trip threw \(error)")
        }
    }

    private mutating func testAllMessageKindsRoundTrip() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_100)
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let envelopes = [
            WorkoutEnvelopeV1(
                kind: .control,
                sessionID: sessionID,
                sessionToken: 7,
                sequence: 1,
                capturedAt: now,
                control: .pause
            ),
            WorkoutEnvelopeV1(
                kind: .acknowledgement,
                sessionID: sessionID,
                sessionToken: 7,
                sequence: 2,
                capturedAt: now,
                acknowledgement: WorkoutAcknowledgementV1(
                    control: .pause,
                    resultingState: .paused,
                    acknowledgedSequence: 1
                )
            ),
            WorkoutEnvelopeV1(
                kind: .error,
                sessionID: sessionID,
                sessionToken: 7,
                sequence: 3,
                capturedAt: now,
                error: WorkoutErrorV1(code: .sessionFailed)
            ),
        ]

        for envelope in envelopes {
            do {
                expect(
                    try WorkoutContractCodec.decode(WorkoutContractCodec.encode(envelope)) == envelope,
                    "\(envelope.kind) should round-trip"
                )
            } catch {
                expect(false, "\(envelope.kind) round-trip threw \(error)")
            }
        }
    }

    private mutating func testCompatibleMinorVersionIgnoresUnknownFields() {
        let envelope = makeEnvelope(
            schemaVersion: WorkoutSchemaVersion(major: 1, minor: 42),
            sequence: 1
        )
        do {
            let original = try PropertyListEncoder().encode(envelope)
            var plist = try PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
            plist["futureOptionalField"] = "ignored"
            let withUnknownField = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            let decoded = try WorkoutContractCodec.decode(withUnknownField)
            expect(decoded.schemaVersion.minor == 42, "compatible minor version should be retained")
        } catch {
            expect(false, "compatible minor version threw \(error)")
        }
    }

    private mutating func testUnsupportedMajorVersionIsRejected() {
        let envelope = makeEnvelope(
            schemaVersion: WorkoutSchemaVersion(major: 2, minor: 0),
            sequence: 1
        )
        do {
            let data = try PropertyListEncoder().encode(envelope)
            expectThrows(.unsupportedSchemaMajor(2), "future schema major") {
                _ = try WorkoutContractCodec.decode(data)
            }
        } catch {
            expect(false, "building future-major fixture threw \(error)")
        }
    }

    private mutating func testOptionalMetricsRemainUnavailable() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let envelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .starting,
                startDate: now
            )
        )
        do {
            let decoded = try WorkoutContractCodec.decode(WorkoutContractCodec.encode(envelope))
            expect(decoded.snapshot?.currentHeartRate == nil, "missing heart rate must remain unavailable")
            expect(decoded.snapshot?.cyclingPower == nil, "missing power must remain unavailable")
            expect(decoded.snapshot?.availability.isEmpty == true, "availability mask must remain empty")
        } catch {
            expect(false, "optional metric fixture threw \(error)")
        }
    }

    private mutating func testInvalidEnvelopeIdentityIsRejected() {
        let emptyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let emptyIDEnvelope = makeEnvelope(sessionID: emptyID, sequence: 1)
        let zeroTokenEnvelope = makeEnvelope(sessionToken: 0, sequence: 1)
        let zeroGenerationEnvelope = makeEnvelope(
            transportGenerationID: emptyID,
            sequence: 1
        )
        expectThrows(.emptySessionID, "empty session ID") {
            try WorkoutContractCodec.validate(emptyIDEnvelope)
        }
        expectThrows(.zeroSessionToken, "zero token") {
            try WorkoutContractCodec.validate(zeroTokenEnvelope)
        }
        expectThrows(.invalidEnvelopePayload, "zero transport generation") {
            try WorkoutContractCodec.validate(zeroGenerationEnvelope)
        }
        expectThrows(.invalidEnvelopePayload, "kind/payload mismatch") {
            try WorkoutContractCodec.validate(
                WorkoutEnvelopeV1(
                    kind: .control,
                    sessionID: UUID(),
                    sessionToken: 1,
                    sequence: 1,
                    capturedAt: Date(),
                    snapshot: WorkoutSnapshotV1(state: .running)
                )
            )
        }
    }

    private mutating func testInvalidNumbersAndCoordinatesAreRejected() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_200)
        let nonFiniteMetricEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentSpeed: metric(.infinity, .metersPerSecond, now, .watchLocation),
                availability: [.currentSpeed]
            )
        )
        let negativeTotalEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                cyclingDistance: metric(-1, .meters, now, .healthKit),
                availability: [.cyclingDistance]
            )
        )
        let validNumbersEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                cyclingDistance: metric(1, .meters, now, .healthKit),
                currentSpeed: metric(0, .metersPerSecond, now, .watchLocation),
                availability: [.cyclingDistance, .currentSpeed]
            )
        )
        let invalidLocationEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                location: WorkoutLocationV1(
                    latitude: 91,
                    longitude: 103,
                    capturedAt: now,
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: nil
                )
            )
        )
        expectThrows(.invalidMetric, "non-finite metric") {
            try WorkoutContractCodec.validate(nonFiniteMetricEnvelope)
        }
        expectThrows(.invalidMetric, "negative total") {
            try WorkoutContractCodec.validate(negativeTotalEnvelope)
        }
        expectThrows(.invalidLocation, "invalid coordinate") {
            try WorkoutContractCodec.validate(invalidLocationEnvelope)
        }
        do {
            try WorkoutContractCodec.validate(validNumbersEnvelope)
        } catch {
            expect(false, "finite nonnegative numeric control should validate: \(error)")
        }
    }

    private mutating func testSequenceGateRejectsDuplicatesAndOlderSnapshots() {
        var gate = WorkoutEnvelopeSequenceGate()
        do {
            expect(try gate.ingest(makeEnvelope(sequence: 0)), "zero may be the first sequence")
            expect(try gate.ingest(makeEnvelope(sequence: 2)), "newer sequence should be accepted")
            expect(!(try gate.ingest(makeEnvelope(sequence: 2))), "duplicate sequence should be rejected")
            expect(!(try gate.ingest(makeEnvelope(sequence: 1))), "older sequence should be rejected")
            expect(try gate.ingest(makeEnvelope(sequence: 3)), "newer sequence should be accepted")
        } catch {
            expect(false, "sequence gate threw \(error)")
        }
    }

    private mutating func testMetricUnitsAndAvailabilityMustMatchPayload() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_300)
        let wrongUnitEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentHeartRate: metric(140, .watts, now),
                availability: [.currentHeartRate]
            )
        )
        let staleAvailabilityEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentHeartRate: metric(140, .beatsPerMinute, now)
            )
        )
        expectThrows(.invalidMetric, "metric unit mismatch") {
            try WorkoutContractCodec.validate(wrongUnitEnvelope)
        }
        expectThrows(.invalidMetric, "availability mismatch") {
            try WorkoutContractCodec.validate(staleAvailabilityEnvelope)
        }
    }

    private mutating func testActiveSnapshotsRequireTrustworthyStartDates() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_350)
        let missingStart = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(state: .running)
        )
        let futureStart = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .paused,
                startDate: now.addingTimeInterval(1)
            )
        )
        expectThrows(.invalidDate, "active snapshot missing start date") {
            try WorkoutContractCodec.validate(missingStart)
        }
        expectThrows(.invalidDate, "start date after capture") {
            try WorkoutContractCodec.validate(futureStart)
        }
    }

    private mutating func testHeartRateMustBePositiveWithoutRejectingMeaningfulZeroes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_375)
        for (label, snapshot) in [
            (
                "current",
                WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    currentHeartRate: metric(0, .beatsPerMinute, now, .healthKit),
                    availability: [.currentHeartRate]
                )
            ),
            (
                "average",
                WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    averageHeartRate: metric(0, .beatsPerMinute, now, .healthKit),
                    availability: [.averageHeartRate]
                )
            ),
        ] {
            let envelope = makeEnvelope(sequence: 1, capturedAt: now, snapshot: snapshot)
            expectThrows(.invalidMetric, "zero \(label) heart rate") {
                try WorkoutContractCodec.validate(envelope)
            }
        }

        let meaningfulZeroes = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                elapsedTime: metric(0, .seconds, now),
                activeEnergy: metric(0, .kilocalories, now, .healthKit),
                cyclingDistance: metric(0, .meters, now, .healthKit),
                currentSpeed: metric(0, .metersPerSecond, now, .watchLocation),
                cyclingPower: metric(0, .watts, now, .healthKit),
                cyclingCadence: metric(0, .revolutionsPerMinute, now, .healthKit),
                availability: [
                    .elapsedTime,
                    .activeEnergy,
                    .cyclingDistance,
                    .currentSpeed,
                    .cyclingPower,
                    .cyclingCadence,
                ]
            )
        )
        do {
            try WorkoutContractCodec.validate(meaningfulZeroes)
        } catch {
            expect(false, "meaningful zero metrics should remain valid: \(error)")
        }
    }

    private mutating func testSpeedRequiresSource() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_400)
        let noSource = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentSpeed: metric(8.2, .metersPerSecond, now),
                availability: [.currentSpeed]
            )
        )
        expectThrows(.invalidMetric, "speed without provenance") {
            try WorkoutContractCodec.validate(noSource)
        }

        for source in [
            WorkoutMetricSourceV1.pairedCyclingSensor,
            .watchLocation,
            .iPhoneLocation,
        ] {
            let withSource = makeEnvelope(
                sequence: 1,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    currentSpeed: metric(8.2, .metersPerSecond, now, source),
                    availability: [.currentSpeed]
                )
            )
            do {
                try WorkoutContractCodec.validate(withSource)
            } catch {
                expect(false, "valid speed source \(source.rawValue) threw \(error)")
            }
        }

        for source in [
            WorkoutMetricSourceV1.healthKit,
            .watchRoute,
            .iPhoneNavigation,
            .unknown,
        ] {
            let invalidSource = makeEnvelope(
                sequence: 1,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    currentSpeed: metric(8.2, .metersPerSecond, now, source),
                    availability: [.currentSpeed]
                )
            )
            expectThrows(.invalidMetric, "invalid speed source \(source.rawValue)") {
                try WorkoutContractCodec.validate(invalidSource)
            }
        }

        do {
            let data = Data(#""futurePrivateSource""#.utf8)
            let source = try JSONDecoder().decode(WorkoutMetricSourceV1.self, from: data)
            expect(source == .unknown, "unknown metric sources should decode to a safe generic case")
        } catch {
            expect(false, "unknown metric source fixture threw \(error)")
        }

        var gate = WorkoutEnvelopeSequenceGate()
        let valid = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentSpeed: metric(8.2, .metersPerSecond, now, .watchLocation),
                availability: [.currentSpeed]
            )
        )
        let invalidHigherSequence = makeEnvelope(
            sequence: 2,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentSpeed: metric(8.2, .metersPerSecond, now, .healthKit),
                availability: [.currentSpeed]
            )
        )
        do {
            expect(try gate.ingest(valid), "valid speed should seed the sequence gate")
        } catch {
            expect(false, "valid speed gate fixture threw \(error)")
        }
        expectThrows(.invalidMetric, "invalid speed must fail before advancing gate state") {
            _ = try gate.ingest(invalidHigherSequence)
        }
        expect(
            gate.highestSequenceBySession[valid.sessionID] == 1,
            "invalid speed must not advance the highest accepted sequence"
        )
        expect(gate.currentSnapshotEnvelope?.sequence == 1, "invalid speed must not replace the snapshot")
    }

    private mutating func testCyclingDistanceRequiresSource() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_450)
        for source in [
            WorkoutMetricSourceV1.healthKit,
            .watchRoute,
            .iPhoneNavigation,
        ] {
            let valid = makeEnvelope(
                sequence: 1,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    cyclingDistance: metric(500, .meters, now, source),
                    availability: [.cyclingDistance]
                )
            )
            do {
                try WorkoutContractCodec.validate(valid)
            } catch {
                expect(false, "valid distance source \(source.rawValue) threw \(error)")
            }
        }

        let invalidSources: [WorkoutMetricSourceV1?] = [
            nil,
            .pairedCyclingSensor,
            .watchLocation,
            .iPhoneLocation,
            .unknown,
        ]
        for source in invalidSources {
            let invalid = makeEnvelope(
                sequence: 1,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    cyclingDistance: metric(500, .meters, now, source),
                    availability: [.cyclingDistance]
                )
            )
            expectThrows(.invalidMetric, "invalid distance source \(source?.rawValue ?? "nil")") {
                try WorkoutContractCodec.validate(invalid)
            }
        }

        var gate = WorkoutEnvelopeSequenceGate()
        let valid = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                cyclingDistance: metric(500, .meters, now, .healthKit),
                availability: [.cyclingDistance]
            )
        )
        let invalidHigherSequence = makeEnvelope(
            sequence: 2,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                cyclingDistance: metric(510, .meters, now, .iPhoneLocation),
                availability: [.cyclingDistance]
            )
        )
        do {
            expect(try gate.ingest(valid), "valid distance should seed the sequence gate")
        } catch {
            expect(false, "valid distance gate fixture threw \(error)")
        }
        expectThrows(.invalidMetric, "invalid distance must fail before advancing gate state") {
            _ = try gate.ingest(invalidHigherSequence)
        }
        expect(
            gate.highestSequenceBySession[valid.sessionID] == 1,
            "invalid distance must not advance the highest accepted sequence"
        )
        expect(gate.currentSnapshotEnvelope?.sequence == 1, "invalid distance must not replace the snapshot")
    }

    private mutating func testComponentTimestampsStayWithinWorkoutWindow() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_500)
        let capturedAt = start.addingTimeInterval(60)
        let validBoundaryEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                currentHeartRate: metric(140, .beatsPerMinute, start, .healthKit),
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: capturedAt,
                    secondsByZone: [30, 30]
                ),
                location: WorkoutLocationV1(
                    latitude: 1.35,
                    longitude: 103.82,
                    capturedAt: capturedAt,
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: nil
                ),
                availability: [.currentHeartRate, .heartRateZone, .location]
            )
        )
        do {
            try WorkoutContractCodec.validate(validBoundaryEnvelope)
        } catch {
            expect(false, "component timestamps at workout boundaries should be valid: \(error)")
        }

        let preStartMetric = makeEnvelope(
            sequence: 1,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                currentHeartRate: metric(
                    140,
                    .beatsPerMinute,
                    start.addingTimeInterval(-1),
                    .healthKit
                ),
                availability: [.currentHeartRate]
            )
        )
        expectThrows(.invalidMetric, "metric captured before workout start") {
            try WorkoutContractCodec.validate(preStartMetric)
        }

        let futureLocation = makeEnvelope(
            sequence: 1,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                location: WorkoutLocationV1(
                    latitude: 1.35,
                    longitude: 103.82,
                    capturedAt: capturedAt.addingTimeInterval(1),
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: nil
                ),
                availability: [.location]
            )
        )
        expectThrows(.invalidLocation, "location captured after envelope") {
            try WorkoutContractCodec.validate(futureLocation)
        }

        let futureZoneDurations = makeEnvelope(
            sequence: 1,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: capturedAt.addingTimeInterval(1),
                    secondsByZone: [30, 30]
                ),
                availability: [.heartRateZone]
            )
        )
        expectThrows(.invalidZone, "zone durations captured after envelope") {
            try WorkoutContractCodec.validate(futureZoneDurations)
        }
    }

    private mutating func testHeartRateZonePayloadIsCoherent() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_600)
        let durationsWithoutCount = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-60),
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: now,
                    secondsByZone: [20, 40]
                ),
                availability: [.heartRateZone]
            )
        )
        expectThrows(.invalidZone, "zone durations without a declared zone count") {
            try WorkoutContractCodec.validate(durationsWithoutCount)
        }

        let missingAvailability = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-60),
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: now,
                    secondsByZone: [20, 40]
                )
            )
        )
        expectThrows(.invalidMetric, "zone payload without availability bit") {
            try WorkoutContractCodec.validate(missingAvailability)
        }

        let coherent = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-60),
                currentHeartRateZone: 2,
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: now,
                    secondsByZone: [20, 40]
                ),
                availability: [.heartRateZone]
            )
        )
        do {
            try WorkoutContractCodec.validate(coherent)
        } catch {
            expect(false, "coherent zone payload should be accepted: \(error)")
        }
    }

    private mutating func testAltitudeRequiresVerticalAccuracy() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_450)
        let locationWithoutAccuracy = WorkoutLocationV1(
            latitude: 1.35,
            longitude: 103.82,
            capturedAt: now,
            horizontalAccuracy: 5,
            altitude: 12,
            verticalAccuracy: nil,
            course: nil,
            speed: nil
        )
        let invalid = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                location: locationWithoutAccuracy,
                availability: [.location, .altitude]
            )
        )
        expectThrows(.invalidLocation, "altitude without vertical accuracy") {
            try WorkoutContractCodec.validate(invalid)
        }

        let horizontalOnly = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                location: WorkoutLocationV1(
                    latitude: 1.35,
                    longitude: 103.82,
                    capturedAt: now,
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: nil
                ),
                availability: [.location]
            )
        )
        do {
            try WorkoutContractCodec.validate(horizontalOnly)
        } catch {
            expect(false, "location without altitude should remain valid: \(error)")
        }
    }

    private mutating func testUnknownErrorCodesBecomeSafeGenericCodes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_500)
        let envelope = WorkoutEnvelopeV1(
            kind: .error,
            sessionID: UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444")!,
            sessionToken: 9,
            sequence: 1,
            capturedAt: now,
            error: WorkoutErrorV1(code: .sessionFailed)
        )
        do {
            let encoded = try PropertyListEncoder().encode(envelope)
            var plist = try PropertyListSerialization.propertyList(from: encoded, format: nil) as! [String: Any]
            var errorPayload = plist["error"] as! [String: Any]
            errorPayload["code"] = "private raw error details"
            plist["error"] = errorPayload
            let futureData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            let decoded = try WorkoutContractCodec.decode(futureData)
            expect(decoded.error?.code == .unknown, "unknown error code should map to a safe generic code")
            let reencoded = try WorkoutContractCodec.encode(decoded)
            let roundTrip = try WorkoutContractCodec.decode(reencoded)
            expect(roundTrip.error?.code == .unknown, "raw unknown error text must not survive re-encoding")
        } catch {
            expect(false, "unknown error fixture threw \(error)")
        }
    }

    private mutating func testSessionIdentityCannotDrift() {
        var gate = WorkoutEnvelopeSequenceGate()
        let sessionID = UUID(uuidString: "ABABABAB-1111-2222-3333-444444444444")!
        let start = Date(timeIntervalSinceReferenceDate: 800_002_500)

        func envelope(
            state: WorkoutSessionStateV1 = .running,
            token: UInt16 = 41,
            sequence: UInt64,
            startDate: Date?
        ) -> WorkoutEnvelopeV1 {
            makeEnvelope(
                sessionID: sessionID,
                sessionToken: token,
                sequence: sequence,
                capturedAt: start.addingTimeInterval(600),
                snapshot: WorkoutSnapshotV1(state: state, startDate: startDate)
            )
        }

        do {
            expect(
                try gate.ingest(envelope(sequence: 1, startDate: start)),
                "first snapshot should establish session identity"
            )
            expect(
                !(try gate.ingest(envelope(token: 42, sequence: 2, startDate: start))),
                "same UUID must not change its session token"
            )
            expect(
                !(try gate.ingest(
                    envelope(sequence: 2, startDate: start.addingTimeInterval(300))
                )),
                "same UUID must not rewrite its workout start date"
            )
            expect(
                !(try gate.ingest(envelope(state: .failed, sequence: 2, startDate: nil))),
                "same UUID must not drop an established workout start date"
            )
            expect(gate.highestSequenceBySession[sessionID] == 1, "identity drift must not advance sequence")
            expect(gate.sessionTokenBySession[sessionID] == 41, "canonical token must remain unchanged")
            expect(gate.startDateBySession[sessionID] == start, "canonical start date must remain unchanged")
            expect(gate.currentSnapshotEnvelope?.sequence == 1, "identity drift must not replace current state")
            expect(
                try gate.ingest(envelope(state: .paused, sequence: 2, startDate: start)),
                "original session identity should remain usable after rejected drift"
            )
        } catch {
            expect(false, "session identity fixture threw \(error)")
        }
    }

    private mutating func testSameSessionCanAdvanceToNewTransportGeneration() {
        var gate = WorkoutEnvelopeSequenceGate()
        let sessionID = UUID(uuidString: "ACACACAC-1111-2222-3333-444444444444")!
        let originalGeneration = UUID(
            uuidString: "ACACACAC-0000-0000-0000-000000000001"
        )!
        let recoveredGeneration = UUID(
            uuidString: "ACACACAC-0000-0000-0000-000000000002"
        )!
        let olderCandidateGeneration = UUID(
            uuidString: "ACACACAC-0000-0000-0000-000000000003"
        )!
        let terminalGeneration = UUID(
            uuidString: "ACACACAC-0000-0000-0000-000000000004"
        )!
        let start = Date(timeIntervalSinceReferenceDate: 800_002_700)

        func envelope(
            token: UInt16,
            generation: UUID,
            sequence: UInt64,
            capturedOffset: TimeInterval,
            state: WorkoutSessionStateV1
        ) -> WorkoutEnvelopeV1 {
            makeEnvelope(
                sessionID: sessionID,
                sessionToken: token,
                transportGenerationID: generation,
                sequence: sequence,
                capturedAt: start.addingTimeInterval(capturedOffset),
                snapshot: WorkoutSnapshotV1(state: state, startDate: start)
            )
        }

        do {
            expect(
                try gate.ingest(
                    envelope(
                        token: 41,
                        generation: originalGeneration,
                        sequence: 9,
                        capturedOffset: 10,
                        state: .running
                    )
                ),
                "the original generation should be accepted"
            )
            expect(
                try gate.ingest(
                    envelope(
                        token: 42,
                        generation: recoveredGeneration,
                        sequence: 4,
                        capturedOffset: 20,
                        state: .paused
                    )
                ),
                "the first observed envelope of a newer generation need not be sequence one"
            )
            expect(gate.sessionTokenBySession[sessionID] == 42, "new token should become canonical")
            expect(gate.highestSequenceBySession[sessionID] == 4, "new generation should reset sequence")
            expect(
                gate.transportGenerationBySession[sessionID] == recoveredGeneration,
                "the explicit transport generation should become canonical"
            )
            expect(
                !(try gate.ingest(
                    envelope(
                        token: 41,
                        generation: originalGeneration,
                        sequence: 10,
                        capturedOffset: 30,
                        state: .paused
                    )
                )),
                "an old generation cannot resume after reset"
            )
            expect(
                !(try gate.ingest(
                    envelope(
                        token: 43,
                        generation: olderCandidateGeneration,
                        sequence: 2,
                        capturedOffset: 15,
                        state: .paused
                    )
                )),
                "an older captured generation reset must be rejected"
            )
            expect(
                try gate.ingest(
                    envelope(
                        token: 42,
                        generation: recoveredGeneration,
                        sequence: 5,
                        capturedOffset: 21,
                        state: .running
                    )
                ),
                "the accepted generation should continue monotonically"
            )
            expect(
                try gate.ingest(
                    envelope(
                        token: 43,
                        generation: terminalGeneration,
                        sequence: 8,
                        capturedOffset: 40,
                        state: .ended
                    )
                ),
                "reconnect may first observe an ended snapshot from an unseen generation"
            )
            expect(
                !(try gate.ingest(
                    envelope(
                        token: 42,
                        generation: recoveredGeneration,
                        sequence: 6,
                        capturedOffset: 50,
                        state: .ended
                    )
                )),
                "a terminal reset must not reopen its retired predecessor"
            )

            var legacyGate = WorkoutEnvelopeSequenceGate()
            let legacySessionID = UUID(
                uuidString: "ACACACAC-1111-2222-3333-555555555555"
            )!
            let legacyToken: UInt16 = 51
            expect(
                try legacyGate.ingest(
                    makeEnvelope(
                        sessionID: legacySessionID,
                        sessionToken: legacyToken,
                        sequence: 9,
                        capturedAt: start.addingTimeInterval(60),
                        snapshot: WorkoutSnapshotV1(
                            state: .running,
                            startDate: start
                        )
                    )
                ),
                "a legacy generation-less envelope should seed migration state"
            )
            expect(
                try legacyGate.ingest(
                    makeEnvelope(
                        sessionID: legacySessionID,
                        sessionToken: legacyToken,
                        transportGenerationID: recoveredGeneration,
                        sequence: 1,
                        capturedAt: start.addingTimeInterval(70),
                        snapshot: WorkoutSnapshotV1(
                            state: .paused,
                            startDate: start
                        )
                    )
                ),
                "the first explicit generation must migrate legacy state even when its token collides"
            )
            expect(
                !(try legacyGate.ingest(
                    makeEnvelope(
                        sessionID: legacySessionID,
                        sessionToken: legacyToken,
                        sequence: 10,
                        capturedAt: start.addingTimeInterval(80),
                        snapshot: WorkoutSnapshotV1(
                            state: .running,
                            startDate: start
                        )
                    )
                )),
                "generation-less legacy replay must remain retired after migration"
            )
        } catch {
            expect(false, "transport generation fixtures threw \(error)")
        }
    }

    private mutating func testSameSessionLifecycleRejectsRegressions() {
        var gate = WorkoutEnvelopeSequenceGate()
        let sessionID = UUID(uuidString: "EEEEEEEE-1111-2222-3333-444444444444")!
        let start = Date(timeIntervalSinceReferenceDate: 800_003_000)

        func envelope(_ state: WorkoutSessionStateV1, sequence: UInt64) -> WorkoutEnvelopeV1 {
            makeEnvelope(
                sessionID: sessionID,
                sequence: sequence,
                capturedAt: start.addingTimeInterval(TimeInterval(sequence)),
                snapshot: WorkoutSnapshotV1(state: state, startDate: start)
            )
        }

        do {
            expect(try gate.ingest(envelope(.running, sequence: 1)), "running should seed the gate")
            expect(try gate.ingest(envelope(.paused, sequence: 2)), "running may transition to paused")
            expect(try gate.ingest(envelope(.running, sequence: 3)), "paused may resume to running")
            expect(
                !(try gate.ingest(envelope(.starting, sequence: 4))),
                "running must not regress to starting"
            )
            expect(gate.highestSequenceBySession[sessionID] == 3, "rejected regression must not advance sequence")
            expect(gate.currentSnapshotEnvelope?.snapshot?.state == .running, "rejected regression must not replace state")
            expect(try gate.ingest(envelope(.ended, sequence: 4)), "lossy delivery may jump running to ended")
            expect(
                !(try gate.ingest(envelope(.running, sequence: 5))),
                "ended must not regress to running"
            )
            expect(gate.highestSequenceBySession[sessionID] == 4, "terminal regression must not advance sequence")
            expect(gate.currentSnapshotEnvelope?.snapshot?.state == .ended, "ended state must remain visible")
        } catch {
            expect(false, "same-session lifecycle fixture threw \(error)")
        }
    }

    private mutating func testBatchPublishesOnlyLatestCoherentSnapshot() {
        var gate = WorkoutEnvelopeSequenceGate()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let batch = [
            makeEnvelope(sequence: 1, snapshot: WorkoutSnapshotV1(state: .starting, startDate: start)),
            makeEnvelope(sequence: 3, snapshot: WorkoutSnapshotV1(state: .running, startDate: start)),
            makeEnvelope(sequence: 2, snapshot: WorkoutSnapshotV1(state: .starting, startDate: start)),
            makeEnvelope(sequence: 4, snapshot: WorkoutSnapshotV1(state: .paused, startDate: start)),
        ]
        let result = gate.ingestBatch(batch)
        expect(result.latestSnapshotEnvelope?.sequence == 4, "batch should publish only the newest accepted sequence")
        expect(result.latestSnapshotEnvelope?.snapshot?.state == .paused, "batch should publish the latest coherent state")
        expect(result.rejections.isEmpty, "valid out-of-order snapshots should not be malformed rejections")
    }

    private mutating func testBatchSkipsInvalidItemsAndContinues() {
        var gate = WorkoutEnvelopeSequenceGate()
        let validOne = makeEnvelope(sequence: 1)
        let invalid = makeEnvelope(sessionToken: 0, sequence: 2)
        let validThree = makeEnvelope(sequence: 3)

        let result = gate.ingestBatch([validOne, invalid, validThree])
        expect(result.latestSnapshotEnvelope?.sequence == 3, "batch must continue to the newest valid snapshot")
        expect(result.rejections == [
            WorkoutEnvelopeBatchRejection(index: 1, error: .zeroSessionToken),
        ], "batch must report the rejected item")
        expect(gate.currentSnapshotEnvelope?.sequence == 3, "gate state should match the published result")
    }

    private mutating func testNewerTerminalSessionReplacesOlderTerminalSession() {
        var gate = WorkoutEnvelopeSequenceGate()
        let oldStart = Date(timeIntervalSinceReferenceDate: 800_002_000)
        let newStart = oldStart.addingTimeInterval(600)
        let oldID = UUID(uuidString: "CCCCCCCC-1111-2222-3333-444444444444")!
        let newID = UUID(uuidString: "DDDDDDDD-1111-2222-3333-444444444444")!

        do {
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: oldID,
                        sequence: 1,
                        capturedAt: oldStart.addingTimeInterval(300),
                        snapshot: WorkoutSnapshotV1(state: .ended, startDate: oldStart)
                    )
                ),
                "old terminal session should seed the gate"
            )
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: newID,
                        sequence: 1,
                        capturedAt: newStart.addingTimeInterval(300),
                        snapshot: WorkoutSnapshotV1(state: .ended, startDate: newStart)
                    )
                ),
                "newer terminal session should replace the old summary"
            )
            expect(gate.currentSnapshotEnvelope?.sessionID == newID, "new terminal summary should be visible")
        } catch {
            expect(false, "terminal replacement threw \(error)")
        }
    }

    private mutating func testOlderSessionCannotReplaceNewerActiveSession() {
        var gate = WorkoutEnvelopeSequenceGate()
        let newerStart = Date(timeIntervalSinceReferenceDate: 800_001_000)
        let olderStart = newerStart.addingTimeInterval(-600)
        let newerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let olderID = UUID(uuidString: "AAAAAAAA-2222-3333-4444-555555555555")!

        do {
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: newerID,
                        sequence: 1,
                        capturedAt: newerStart,
                        snapshot: WorkoutSnapshotV1(state: .running, startDate: newerStart)
                    )
                ),
                "newer active session should be accepted"
            )
            expect(
                !(try gate.ingest(
                    makeEnvelope(
                        sessionID: olderID,
                        sequence: 99,
                        capturedAt: newerStart.addingTimeInterval(60),
                        snapshot: WorkoutSnapshotV1(state: .running, startDate: olderStart)
                    )
                )),
                "older session must not replace the newer active session"
            )
            expect(gate.currentSnapshotEnvelope?.sessionID == newerID, "newer session should remain visible")
        } catch {
            expect(false, "cross-session gate threw \(error)")
        }
    }

    private mutating func testActiveSessionReplacesIdlePlaceholderRegardlessOfDeliveryOrder() {
        var gate = WorkoutEnvelopeSequenceGate()
        let activeStart = Date(timeIntervalSinceReferenceDate: 800_003_500)
        let idleID = UUID(uuidString: "12121212-1111-2222-3333-444444444444")!
        let activeID = UUID(uuidString: "34343434-1111-2222-3333-444444444444")!

        do {
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: idleID,
                        sequence: 1,
                        capturedAt: activeStart.addingTimeInterval(120),
                        snapshot: WorkoutSnapshotV1(state: .idle)
                    )
                ),
                "idle placeholder should seed the gate"
            )
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: activeID,
                        sequence: 1,
                        capturedAt: activeStart.addingTimeInterval(60),
                        snapshot: WorkoutSnapshotV1(state: .running, startDate: activeStart)
                    )
                ),
                "active workout must replace an idle placeholder delivered first"
            )
            expect(gate.currentSnapshotEnvelope?.sessionID == activeID, "active workout should be visible")
        } catch {
            expect(false, "active-over-idle fixture threw \(error)")
        }
    }

    private mutating func testActiveSessionReplacesFailedAttemptRegardlessOfDeliveryOrder() {
        var gate = WorkoutEnvelopeSequenceGate()
        let activeStart = Date(timeIntervalSinceReferenceDate: 800_004_000)
        let failedID = UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!
        let activeID = UUID(uuidString: "99999999-1111-2222-3333-444444444444")!

        do {
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: failedID,
                        sequence: 1,
                        capturedAt: activeStart.addingTimeInterval(120),
                        snapshot: WorkoutSnapshotV1(state: .failed)
                    )
                ),
                "failed start attempt should seed the gate"
            )
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: activeID,
                        sequence: 1,
                        capturedAt: activeStart.addingTimeInterval(60),
                        snapshot: WorkoutSnapshotV1(state: .running, startDate: activeStart)
                    )
                ),
                "active workout must replace a failed attempt even when delivered in reverse order"
            )
            expect(gate.currentSnapshotEnvelope?.sessionID == activeID, "active workout should be visible")
        } catch {
            expect(false, "active-over-failed fixture threw \(error)")
        }
    }

    private mutating func testEndedSessionReplacesOnlyOlderPlaceholders() {
        let workoutStart = Date(timeIntervalSinceReferenceDate: 800_004_500)
        for (index, placeholderState) in [
            WorkoutSessionStateV1.idle,
            .failed,
        ].enumerated() {
            let placeholderID = UUID(uuidString: index == 0
                ? "56565656-1111-2222-3333-444444444444"
                : "78787878-1111-2222-3333-444444444444")!
            let endedID = UUID(uuidString: index == 0
                ? "90909090-1111-2222-3333-444444444444"
                : "A0A0A0A0-1111-2222-3333-444444444444")!
            let endedEnvelope = makeEnvelope(
                sessionID: endedID,
                sequence: 1,
                capturedAt: workoutStart.addingTimeInterval(200),
                snapshot: WorkoutSnapshotV1(state: .ended, startDate: workoutStart)
            )

            var acceptsNewerEnded = WorkoutEnvelopeSequenceGate()
            var rejectsOlderEnded = WorkoutEnvelopeSequenceGate()
            do {
                expect(
                    try acceptsNewerEnded.ingest(
                        makeEnvelope(
                            sessionID: placeholderID,
                            sequence: 1,
                            capturedAt: workoutStart.addingTimeInterval(100),
                            snapshot: WorkoutSnapshotV1(state: placeholderState)
                        )
                    ),
                    "\(placeholderState) should seed newer-ended acceptance gate"
                )
                expect(
                    try acceptsNewerEnded.ingest(endedEnvelope),
                    "later-captured ended workout should replace \(placeholderState)"
                )
                expect(
                    acceptsNewerEnded.currentSnapshotEnvelope?.sessionID == endedID,
                    "ended workout should be visible after \(placeholderState)"
                )

                expect(
                    try rejectsOlderEnded.ingest(
                        makeEnvelope(
                            sessionID: placeholderID,
                            sequence: 1,
                            capturedAt: workoutStart.addingTimeInterval(300),
                            snapshot: WorkoutSnapshotV1(state: placeholderState)
                        )
                    ),
                    "\(placeholderState) should seed older-ended rejection gate"
                )
                expect(
                    !(try rejectsOlderEnded.ingest(endedEnvelope)),
                    "older-captured ended workout must not replace \(placeholderState)"
                )
                expect(
                    rejectsOlderEnded.currentSnapshotEnvelope?.sessionID == placeholderID,
                    "newer \(placeholderState) should remain visible"
                )
                expect(
                    rejectsOlderEnded.highestSequenceBySession[endedID] == nil,
                    "rejected ended workout must not mutate sequence state"
                )
            } catch {
                expect(false, "ended-over-\(placeholderState) fixture threw \(error)")
            }
        }
    }

    private mutating func testWatchLifecycleRequiresHealthKitConfirmationAndFinalizesOnce() {
        var saveReducer = WorkoutLifecycleReducer()
        expect(saveReducer.apply(.requestStart), "idle workout should accept start")
        expect(saveReducer.state == .starting, "start request should enter starting")
        expect(!saveReducer.apply(.requestStart), "active workout must reject a second start")
        expect(saveReducer.apply(.sessionRunning), "HealthKit running callback should be accepted")
        expect(saveReducer.state == .running, "delegate callback should enter running")

        // There is intentionally no optimistic pause request event. The state
        // remains running until HealthKit confirms the transition.
        expect(saveReducer.state == .running, "pause request alone must not change state")
        expect(saveReducer.apply(.sessionPaused), "HealthKit pause callback should be accepted")
        expect(saveReducer.state == .paused, "delegate callback should enter paused")
        expect(saveReducer.apply(.sessionRunning), "HealthKit resume callback should be accepted")

        expect(
            saveReducer.apply(.requestEnd(.save)),
            "running workout should accept save finalization"
        )
        expect(saveReducer.state == .ending, "end request should enter ending")
        expect(
            saveReducer.claimFinalization() == .save,
            "save disposition should be claimable exactly once"
        )
        expect(
            saveReducer.claimFinalization() == nil,
            "duplicate stopped callbacks must not save a second workout"
        )
        saveReducer.releaseFinalizationClaimForRetry()
        expect(
            saveReducer.claimFinalization() == .save,
            "a retryable save failure should make the same disposition claimable again"
        )
        expect(
            saveReducer.claimFinalization() == nil,
            "a retried finalization must still be single-claim"
        )
        expect(saveReducer.apply(.sessionEnded), "successful finalization should enter ended")
        expect(!saveReducer.apply(.fail), "ended workout must not regress to failed")

        var discardReducer = WorkoutLifecycleReducer()
        expect(discardReducer.apply(.requestStart), "discard fixture should start")
        expect(discardReducer.apply(.sessionRunning), "discard fixture should run")
        expect(discardReducer.apply(.requestEnd(.discard)), "discard should enter ending")
        expect(
            discardReducer.claimFinalization() == .discard,
            "discard disposition should not become save"
        )
        expect(discardReducer.apply(.sessionEnded), "discard should finish as ended")
        expect(discardReducer.apply(.reset), "summary dismissal should return to idle")
    }

    private mutating func testWorkoutLifecycleFailureAndLateRunningPolicies() {
        expect(
            WorkoutSessionFailurePolicy.action(for: .starting) == .failStart,
            "pre-running session failure must discard the startup attempt"
        )
        expect(
            WorkoutSessionFailurePolicy.action(for: .running) == .savePartialWorkout,
            "a running failure may save the partial workout"
        )
        expect(
            WorkoutSessionFailurePolicy.action(for: .paused) == .savePartialWorkout,
            "a paused failure may save the partial workout"
        )
        expect(
            WorkoutSessionFailurePolicy.action(for: .ending) == .finishRequestedDisposition,
            "a failure during ending must retain the requested save/discard disposition"
        )
        expect(
            WorkoutSessionFailurePolicy.action(for: .ended) == .ignore,
            "terminal sessions must ignore later failures"
        )
        expect(
            WorkoutRunningCallbackPolicy.action(for: .starting) == .enterRunning,
            "normal startup should accept the running callback"
        )
        expect(
            WorkoutRunningCallbackPolicy.action(for: .ending) == .stopSession,
            "a late running callback after quick end must reissue session stop"
        )
        expect(
            WorkoutRunningCallbackPolicy.action(for: .failed) == .ignore,
            "a failed workout must ignore a late running callback"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: true,
                pendingDisposition: .save
            ) == .adoptEnded(.save),
            "a session that ends during metadata repair must retain its pending save"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: true,
                isEndedAfterMetadataRepair: true,
                pendingDisposition: .discard
            ) == .adoptEnded(.discard),
            "an already-ended recovery must retain its pending discard"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: true,
                pendingDisposition: nil
            ) == .adoptEnded(.save),
            "an unexpectedly ended recovery should default to preserving the ride"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: false,
                isStoppedAfterMetadataRepair: true,
                pendingDisposition: nil
            ) == .adoptStopped(.save),
            "an unexpectedly stopped recovery must create a durable default save request"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: false,
                isStoppedAfterMetadataRepair: true,
                pendingDisposition: .discard
            ) == .adoptStopped(.discard),
            "a stopped recovery must preserve an existing discard request"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: false,
                pendingDisposition: .discard
            ) == .adopt,
            "a still-active session should remain eligible for recovery adoption"
        )
    }

    private mutating func testWorkoutFinalizationOrchestratorOrderAndFailures() async {
        enum SyntheticFailure: Error {
            case expected
        }

        var saveEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                discardWorkout: { saveEvents.append("discard-workout") },
                discardRoute: { saveEvents.append("discard-route") },
                prepareRoute: {
                    saveEvents.append("prepare-route")
                    return WorkoutPreparedRoute(
                        routeKnownPresent: true,
                        distanceMeters: 123
                    )
                },
                markPreparedRoute: { status in
                    saveEvents.append("route-\(status.rawValue)")
                },
                endCollection: { saveEvents.append("end-collection") },
                markCollectionEnded: { saveEvents.append("phase-collection-ended") },
                markFinishAttempted: { saveEvents.append("phase-finish-attempted") },
                finishWorkout: { saveEvents.append("finish-workout") },
                markFinishFailed: { saveEvents.append("phase-finish-failed") },
                markWorkoutSaved: { saveEvents.append("phase-workout-saved") },
                endSession: { saveEvents.append("end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(
                        routeKnownPresent: true,
                        distanceMeters: 123
                    )
                ),
                "save orchestrator should return the prepared route exactly"
            )
            expect(
                saveEvents == [
                    "prepare-route",
                    "route-present",
                    "end-collection",
                    "phase-collection-ended",
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-workout-saved",
                    "end-session",
                ],
                "save orchestrator must flush and finish before ending the session"
            )
        } catch {
            expect(false, "successful finalization orchestrator threw \(error)")
        }

        var discardEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .discard,
                discardWorkout: { discardEvents.append("discard-workout") },
                discardRoute: { discardEvents.append("discard-route") },
                prepareRoute: {
                    discardEvents.append("prepare-route")
                    return WorkoutPreparedRoute(
                        routeKnownPresent: true,
                        distanceMeters: 123
                    )
                },
                endCollection: { discardEvents.append("end-collection") },
                finishWorkout: { discardEvents.append("finish-workout") },
                endSession: { discardEvents.append("end-session") }
            )
            expect(outcome == .discarded, "discard orchestrator should return discarded")
            expect(
                discardEvents == ["discard-workout", "discard-route", "end-session"],
                "discard must save nothing before ending the session"
            )
        } catch {
            expect(false, "discard orchestrator threw \(error)")
        }

        var endFailureEvents: [String] = []
        do {
            _ = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                discardWorkout: { endFailureEvents.append("discard-workout") },
                discardRoute: { endFailureEvents.append("discard-route") },
                prepareRoute: {
                    endFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(
                        routeKnownPresent: false,
                        distanceMeters: nil
                    )
                },
                endCollection: {
                    endFailureEvents.append("end-collection")
                    throw SyntheticFailure.expected
                },
                finishWorkout: { endFailureEvents.append("finish-workout") },
                endSession: { endFailureEvents.append("end-session") }
            )
            expect(false, "end-collection failure should propagate")
        } catch {
            expect(
                endFailureEvents == [
                    "prepare-route",
                    "end-collection",
                ],
                "endCollection failure must retain the stopped builder, route, and session for retry"
            )
        }
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                discardWorkout: { endFailureEvents.append("retry-discard-workout") },
                discardRoute: { endFailureEvents.append("retry-discard-route") },
                prepareRoute: {
                    endFailureEvents.append("retry-prepare-route")
                    return WorkoutPreparedRoute(routeKnownPresent: false, distanceMeters: nil)
                },
                endCollection: { endFailureEvents.append("retry-end-collection") },
                finishWorkout: { endFailureEvents.append("retry-finish-workout") },
                endSession: { endFailureEvents.append("retry-end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeKnownPresent: false, distanceMeters: nil)
                ),
                "endCollection failure should be retryable without a destructive cleanup"
            )
            expect(
                endFailureEvents == [
                    "prepare-route",
                    "end-collection",
                    "retry-prepare-route",
                    "retry-end-collection",
                    "retry-finish-workout",
                    "retry-end-session",
                ],
                "a retried full save should finish once and only then end session mode"
            )
        } catch {
            expect(false, "end-collection retry should succeed: \(error)")
        }

        var finishFailureEvents: [String] = []
        do {
            _ = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                discardWorkout: { finishFailureEvents.append("discard-workout") },
                discardRoute: { finishFailureEvents.append("discard-route") },
                prepareRoute: {
                    finishFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(
                        routeKnownPresent: false,
                        distanceMeters: nil
                    )
                },
                markPreparedRoute: { status in
                    finishFailureEvents.append("route-\(status.rawValue)")
                },
                endCollection: { finishFailureEvents.append("end-collection") },
                markCollectionEnded: {
                    finishFailureEvents.append("phase-collection-ended")
                },
                markFinishAttempted: {
                    finishFailureEvents.append("phase-finish-attempted")
                },
                finishWorkout: {
                    finishFailureEvents.append("finish-workout")
                    throw SyntheticFailure.expected
                },
                markFinishFailed: {
                    finishFailureEvents.append("phase-finish-failed")
                },
                endSession: { finishFailureEvents.append("end-session") }
            )
            expect(false, "finish-workout failure should propagate")
        } catch {
            expect(
                    finishFailureEvents
                    == [
                        "prepare-route",
                        "route-unavailable",
                        "end-collection",
                        "phase-collection-ended",
                        "phase-finish-attempted",
                        "finish-workout",
                        "phase-finish-failed",
                    ],
                    "finish failure must retain the collection-ended builder and session for reconciliation"
            )
        }
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { finishFailureEvents.append("retry-discard-workout") },
                discardRoute: { finishFailureEvents.append("retry-discard-route") },
                prepareRoute: {
                    finishFailureEvents.append("retry-prepare-route")
                    return WorkoutPreparedRoute(routeKnownPresent: false, distanceMeters: nil)
                },
                endCollection: { finishFailureEvents.append("retry-end-collection") },
                markFinishAttempted: {
                    finishFailureEvents.append("retry-phase-finish-attempted")
                },
                finishWorkout: { finishFailureEvents.append("retry-finish-workout") },
                markWorkoutSaved: {
                    finishFailureEvents.append("phase-workout-saved")
                },
                endSession: { finishFailureEvents.append("retry-end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                ),
                "finishWorkout failure should retry from the durable collection-ended phase"
            )
            expect(
                finishFailureEvents == [
                    "prepare-route",
                    "route-unavailable",
                    "end-collection",
                    "phase-collection-ended",
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-finish-failed",
                    "retry-phase-finish-attempted",
                    "retry-finish-workout",
                    "phase-workout-saved",
                    "retry-end-session",
                ],
                "finish retry must not end collection or discard resources a second time"
            )
        } catch {
            expect(false, "finish-workout retry should succeed: \(error)")
        }

        var finishMarkerFailureEvents: [String] = []
        do {
            _ = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { finishMarkerFailureEvents.append("discard-workout") },
                discardRoute: { finishMarkerFailureEvents.append("discard-route") },
                prepareRoute: {
                    finishMarkerFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                },
                endCollection: { finishMarkerFailureEvents.append("end-collection") },
                markFinishAttempted: {
                    finishMarkerFailureEvents.append("phase-finish-attempted")
                    throw SyntheticFailure.expected
                },
                finishWorkout: { finishMarkerFailureEvents.append("finish-workout") },
                endSession: { finishMarkerFailureEvents.append("end-session") }
            )
            expect(false, "finish-attempt persistence failure should propagate")
        } catch {
            expect(
                finishMarkerFailureEvents == ["phase-finish-attempted"],
                "the HealthKit save call must not start unless its commit-unknown marker is durable"
            )
        }

        var savedMarkerFailureEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { savedMarkerFailureEvents.append("discard-workout") },
                discardRoute: { savedMarkerFailureEvents.append("discard-route") },
                prepareRoute: {
                    savedMarkerFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                },
                recoveredRouteStatus: .unknown,
                endCollection: { savedMarkerFailureEvents.append("end-collection") },
                markFinishAttempted: {
                    savedMarkerFailureEvents.append("phase-finish-attempted")
                },
                finishWorkout: { savedMarkerFailureEvents.append("finish-workout") },
                markWorkoutSaved: {
                    savedMarkerFailureEvents.append("phase-workout-saved")
                    throw SyntheticFailure.expected
                },
                workoutSavedPersistenceFailed: {
                    savedMarkerFailureEvents.append("phase-workout-saved-pending")
                },
                endSession: { savedMarkerFailureEvents.append("end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                ),
                "a definitive HealthKit finish success must remain saved when its local marker fails"
            )
            expect(
                savedMarkerFailureEvents == [
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-workout-saved",
                    "phase-workout-saved-pending",
                    "end-session",
                ],
                "marker failure after finish success must still end session exactly once"
            )
        } catch {
            expect(false, "post-success marker failure must not replace HealthKit success: \(error)")
        }

        var rollbackFailureEvents: [String] = []
        do {
            _ = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { rollbackFailureEvents.append("discard-workout") },
                discardRoute: { rollbackFailureEvents.append("discard-route") },
                prepareRoute: {
                    rollbackFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                },
                endCollection: { rollbackFailureEvents.append("end-collection") },
                markFinishAttempted: {
                    rollbackFailureEvents.append("phase-finish-attempted")
                },
                finishWorkout: {
                    rollbackFailureEvents.append("finish-workout")
                    throw SyntheticFailure.expected
                },
                markFinishFailed: {
                    rollbackFailureEvents.append("phase-finish-failed")
                    throw SyntheticFailure.expected
                },
                endSession: { rollbackFailureEvents.append("end-session") }
            )
            expect(false, "failed rollback persistence should remain retryable in memory")
        } catch WorkoutFinalizationPersistenceError.finishFailureRollbackPending {
            expect(
                rollbackFailureEvents == [
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-finish-failed",
                ],
                "known finish failure must not end or call finish again before rollback persists"
            )
        } catch {
            expect(false, "rollback persistence failure used the wrong error: \(error)")
        }

        var collectionEndedRecoveryEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { collectionEndedRecoveryEvents.append("discard-workout") },
                discardRoute: { collectionEndedRecoveryEvents.append("discard-route") },
                completeAlreadySavedRoute: {
                    collectionEndedRecoveryEvents.append("complete-saved-route")
                },
                prepareRoute: {
                    collectionEndedRecoveryEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeKnownPresent: true, distanceMeters: 1)
                },
                recoveredRouteStatus: .present,
                endCollection: { collectionEndedRecoveryEvents.append("end-collection") },
                markCollectionEnded: {
                    collectionEndedRecoveryEvents.append("phase-collection-ended")
                },
                markFinishAttempted: {
                    collectionEndedRecoveryEvents.append("phase-finish-attempted")
                },
                finishWorkout: { collectionEndedRecoveryEvents.append("finish-workout") },
                markWorkoutSaved: {
                    collectionEndedRecoveryEvents.append("phase-workout-saved")
                },
                endSession: { collectionEndedRecoveryEvents.append("end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeStatus: .present, distanceMeters: nil)
                ),
                "collection-ended recovery should report an honest unknown route"
            )
            expect(
                collectionEndedRecoveryEvents == [
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-workout-saved",
                    "end-session",
                ],
                "collection-ended recovery must invoke the save adapter once without ending collection again"
            )
        } catch {
            expect(false, "collection-ended recovery threw \(error)")
        }

        var alreadySavedRecoveryEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .alreadySaved,
                discardWorkout: { alreadySavedRecoveryEvents.append("discard-workout") },
                discardRoute: { alreadySavedRecoveryEvents.append("discard-route") },
                completeAlreadySavedRoute: {
                    alreadySavedRecoveryEvents.append("complete-saved-route")
                },
                prepareRoute: {
                    alreadySavedRecoveryEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeKnownPresent: true, distanceMeters: 1)
                },
                recoveredRouteStatus: .present,
                endCollection: { alreadySavedRecoveryEvents.append("end-collection") },
                markCollectionEnded: {
                    alreadySavedRecoveryEvents.append("phase-collection-ended")
                },
                finishWorkout: { alreadySavedRecoveryEvents.append("finish-workout") },
                markWorkoutSaved: {
                    alreadySavedRecoveryEvents.append("phase-workout-saved")
                },
                endSession: { alreadySavedRecoveryEvents.append("end-session") }
            )
            expect(
                alreadySavedRecoveryEvents == ["complete-saved-route", "end-session"],
                "already-saved recovery must not invoke the workout save adapter a second time"
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeStatus: .present, distanceMeters: nil)
                ),
                "already-saved recovery must retain the durable known-present route state"
            )
        } catch {
            expect(false, "already-saved recovery threw \(error)")
        }
    }

    private mutating func testWorkoutFinishAndRecoveryPolicies() {
        expect(
            WorkoutFinishCallbackPolicy.outcome(
                workoutReturned: true,
                errorReturned: false
            ) == .saved,
            "a returned workout with no error should be a successful save"
        )
        expect(
            WorkoutFinishCallbackPolicy.outcome(
                workoutReturned: false,
                errorReturned: false
            ) == .saved,
            "locked-device nil workout with no error should still be a successful save"
        )
        expect(
            WorkoutFinishCallbackPolicy.outcome(
                workoutReturned: true,
                errorReturned: true
            ) == .failed,
            "an explicit finish error must win over a returned object"
        )
        expect(
            WorkoutRecoveryInitializationPolicy.shouldClearDurableIdentity(after: .none),
            "confirmed absence of an active workout should clear durable identity"
        )
        expect(
            !WorkoutRecoveryInitializationPolicy.shouldClearDurableIdentity(after: .failed),
            "a transient recovery error must preserve durable identity for retry"
        )
        expect(
            WorkoutRecoverySingleFlightPolicy.canStartRetry(
                isWorkoutActive: false,
                isRecovering: false
            ),
            "idle recovery should allow one retry"
        )
        expect(
            !WorkoutRecoverySingleFlightPolicy.canStartRetry(
                isWorkoutActive: false,
                isRecovering: true
            ),
            "an in-flight recovery must reject a second retry"
        )
        expect(
            !WorkoutRecoverySingleFlightPolicy.canStartRetry(
                isWorkoutActive: true,
                isRecovering: false
            ),
            "an attached active workout must reject recovery retry"
        )
        let callbackDate = Date(timeIntervalSinceReferenceDate: 800_019_000)
        let stoppedDate = callbackDate.addingTimeInterval(-15)
        expect(
            WorkoutFinalizationEndDatePolicy.resolve(
                authoritativeEndDate: stoppedDate,
                callbackDate: callbackDate
            ) == stoppedDate,
            "recovered stopped workouts must retain the HealthKit end date"
        )
        expect(
            WorkoutFinalizationEndDatePolicy.resolve(
                authoritativeEndDate: nil,
                callbackDate: callbackDate
            ) == callbackDate,
            "ordinary finalization should use the ended callback date"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .requested,
                builderCollectionEnded: false,
                matchingWorkout: .notFound
            ) == .finalize(.full),
            "requested recovery with no saved match should run full finalization"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .requested,
                builderCollectionEnded: true,
                matchingWorkout: .notFound
            ) == .finalize(.finishOnly),
            "a builder that already ended collection must not end it twice"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .collectionEnded,
                builderCollectionEnded: false,
                matchingWorkout: .notFound
            ) == .finalize(.finishOnly),
            "durable collection-ended state should resume at finishWorkout"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .finishAttempted,
                builderCollectionEnded: true,
                matchingWorkout: .notFound
            ) == .retryReconciliation,
            "one empty query after a finish attempt must remain commit-unknown"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .finishAttempted,
                builderCollectionEnded: true,
                matchingWorkout: .notFound
            ) == .retryReconciliation,
            "repeated no-match queries must never infer that finishWorkout failed"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .finishAttempted,
                builderCollectionEnded: true,
                matchingWorkout: .unavailable
            ) == .retryReconciliation,
            "an unreadable commit-unknown workout must remain explicitly unresolved"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .finishAttempted,
                builderCollectionEnded: true,
                matchingWorkout: .found
            ) == .finalize(.alreadySaved),
            "readable confirmation after a finish attempt must suppress a second save"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .requested,
                builderCollectionEnded: true,
                matchingWorkout: .found
            ) == .finalize(.alreadySaved),
            "a matching stable workout identifier must suppress a second save"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .workoutSaved,
                builderCollectionEnded: true,
                matchingWorkout: .queryFailed
            ) == .finalize(.alreadySaved),
            "durable workout-saved state must remain authoritative during query failure"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .requested,
                builderCollectionEnded: true,
                matchingWorkout: .queryFailed
            ) == .retryReconciliation,
            "ambiguous query failure must not call the save adapter"
        )
    }

    private mutating func testMetricPrecedenceDoesNotCombineOrInventSources() {
        let now = Date(timeIntervalSinceReferenceDate: 800_020_000)
        let healthDistance = WorkoutMetricCandidate(
            value: 1_000,
            capturedAt: now,
            source: .healthKit
        )
        let routeDistance = WorkoutMetricCandidate(
            value: 950,
            capturedAt: now,
            source: .watchRoute
        )
        expect(
            WorkoutMetricPrecedence.cyclingDistance(
                healthKit: healthDistance,
                watchRoute: routeDistance
            ) == healthDistance,
            "HealthKit distance should win without adding route distance"
        )
        expect(
            WorkoutMetricPrecedence.cyclingDistance(
                healthKit: nil,
                watchRoute: routeDistance
            ) == routeDistance,
            "route distance should fill only when HealthKit distance is unavailable"
        )

        let sensorSpeed = WorkoutMetricCandidate(
            value: 8.5,
            capturedAt: now,
            source: .pairedCyclingSensor
        )
        let locationSpeed = WorkoutMetricCandidate(
            value: 7.8,
            capturedAt: now,
            source: .watchLocation
        )
        expect(
            WorkoutMetricPrecedence.currentSpeed(
                pairedSensor: sensorSpeed,
                watchLocation: locationSpeed
            ) == sensorSpeed,
            "paired cycling sensor should win over Watch location"
        )
        expect(
            WorkoutMetricPrecedence.currentSpeed(
                pairedSensor: WorkoutMetricCandidate(
                    value: .nan,
                    capturedAt: now,
                    source: .pairedCyclingSensor
                ),
                watchLocation: locationSpeed
            ) == locationSpeed,
            "invalid sensor speed should fall back to a valid location speed"
        )
        expect(
            WorkoutMetricPrecedence.currentSpeed(
                pairedSensor: WorkoutMetricCandidate(
                    value: 9,
                    capturedAt: now,
                    source: .healthKit
                ),
                watchLocation: nil
            ) == nil,
            "a semantically wrong source must remain unavailable"
        )
    }

    private mutating func testInstantaneousMetricFreshnessAndSpeedFallback() {
        let now = Date(timeIntervalSinceReferenceDate: 800_025_000)
        let sensorAtBoundary = WorkoutMetricCandidate(
            value: 8.5,
            capturedAt: now.addingTimeInterval(
                -WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
            ),
            source: .pairedCyclingSensor
        )
        let staleSensor = WorkoutMetricCandidate(
            value: 9,
            capturedAt: sensorAtBoundary.capturedAt.addingTimeInterval(-0.001),
            source: .pairedCyclingSensor
        )
        let freshLocation = WorkoutMetricCandidate(
            value: 7.8,
            capturedAt: now.addingTimeInterval(-1),
            source: .watchLocation
        )
        expect(
            WorkoutMetricFreshness.candidate(
                sensorAtBoundary,
                now: now,
                maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
            ) == sensorAtBoundary,
            "instantaneous sensor value should remain fresh at its age boundary"
        )
        let freshSensor = WorkoutMetricFreshness.candidate(
            staleSensor,
            now: now,
            maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
        )
        expect(freshSensor == nil, "sensor value beyond the age limit must expire")
        expect(
            WorkoutMetricPrecedence.currentSpeed(
                pairedSensor: freshSensor,
                watchLocation: freshLocation
            ) == freshLocation,
            "fresh Watch GPS speed must replace an expired paired-sensor speed"
        )

        let heartRateAtBoundary = WorkoutMetricV1(
            value: 142,
            unit: .beatsPerMinute,
            capturedAt: now.addingTimeInterval(-WorkoutMetricFreshness.heartRateMaximumAge),
            source: .healthKit
        )
        expect(
            WorkoutMetricFreshness.metric(
                heartRateAtBoundary,
                now: now,
                maximumAge: WorkoutMetricFreshness.heartRateMaximumAge
            ) == heartRateAtBoundary,
            "heart rate should remain fresh at its boundary"
        )
        expect(
            WorkoutMetricFreshness.metric(
                WorkoutMetricV1(
                    value: 143,
                    unit: .beatsPerMinute,
                    capturedAt: now.addingTimeInterval(1),
                    source: .healthKit
                ),
                now: now,
                maximumAge: WorkoutMetricFreshness.heartRateMaximumAge
            ) == nil,
            "future instantaneous readings must fail closed"
        )
    }

    private mutating func testBuilderElapsedTimeUsesHealthKitPauseClock() {
        let start = Date(timeIntervalSinceReferenceDate: 800_027_000)
        let running = WorkoutElapsedTimePolicy.metric(
            builderElapsedTime: 30,
            startDate: start,
            capturedAt: start.addingTimeInterval(30)
        )
        let pausedLater = WorkoutElapsedTimePolicy.metric(
            builderElapsedTime: 30,
            startDate: start,
            capturedAt: start.addingTimeInterval(50)
        )
        let resumed = WorkoutElapsedTimePolicy.metric(
            builderElapsedTime: 31,
            startDate: start,
            capturedAt: start.addingTimeInterval(51)
        )
        expect(running?.value == 30, "running snapshot should use builder elapsed time")
        expect(
            pausedLater?.value == running?.value,
            "wall-clock time during pause must not advance elapsed workout time"
        )
        expect(
            resumed?.value == 31,
            "elapsed time should advance again only when the builder does"
        )
        expect(
            WorkoutElapsedTimePolicy.metric(
                builderElapsedTime: .nan,
                startDate: start,
                capturedAt: start
            ) == nil,
            "invalid builder elapsed time must remain unavailable"
        )
    }

    private mutating func testRoutePointFilteringHonorsWorkoutAndAccuracyBounds() {
        let start = Date(timeIntervalSinceReferenceDate: 800_030_000)
        let now = start.addingTimeInterval(30)
        let valid = WorkoutRoutePointCandidate(
            latitude: 1.3521,
            longitude: 103.8198,
            capturedAt: now,
            horizontalAccuracy: 6,
            verticalAccuracy: 8
        )
        expect(
            WorkoutRoutePointFilter.accepts(valid, workoutStart: start, now: now),
            "accurate in-window route point should be accepted"
        )
        expect(
            !WorkoutRoutePointFilter.accepts(
                WorkoutRoutePointCandidate(
                    latitude: valid.latitude,
                    longitude: valid.longitude,
                    capturedAt: start.addingTimeInterval(-1),
                    horizontalAccuracy: valid.horizontalAccuracy,
                    verticalAccuracy: valid.verticalAccuracy
                ),
                workoutStart: start,
                now: now
            ),
            "pre-workout route point should be rejected"
        )
        expect(
            !WorkoutRoutePointFilter.accepts(
                WorkoutRoutePointCandidate(
                    latitude: valid.latitude,
                    longitude: valid.longitude,
                    capturedAt: now,
                    horizontalAccuracy: 51,
                    verticalAccuracy: valid.verticalAccuracy
                ),
                workoutStart: start,
                now: now
            ),
            "inaccurate route point should be rejected"
        )
        expect(
            !WorkoutRoutePointFilter.accepts(
                WorkoutRoutePointCandidate(
                    latitude: 91,
                    longitude: valid.longitude,
                    capturedAt: now,
                    horizontalAccuracy: valid.horizontalAccuracy,
                    verticalAccuracy: valid.verticalAccuracy
                ),
                workoutStart: start,
                now: now
            ),
            "invalid coordinate should be rejected"
        )
    }

    private mutating func testRouteTimestampGateRejectsDelayedPausedBatches() {
        let start = Date(timeIntervalSinceReferenceDate: 800_035_000)
        var gate = WorkoutRouteTimestampGate(workoutStart: start)
        expect(gate.accepts(start), "route timestamp gate should include workout start")

        let resumeDate = start.addingTimeInterval(30)
        gate.resume(at: resumeDate)
        expect(
            !gate.accepts(resumeDate.addingTimeInterval(-0.001)),
            "a paused point delivered after resume must still be rejected by capture time"
        )
        expect(
            gate.accepts(resumeDate),
            "a point captured at the resume boundary should be accepted"
        )
        gate.resume(at: start.addingTimeInterval(10))
        expect(
            gate.minimumAcceptedAt == resumeDate,
            "an out-of-order resume callback must not move the gate backward"
        )
    }

    private mutating func testRouteSegmentAndQueueBounds() {
        expect(
            WorkoutRouteSegmentFilter.accepts(distanceMeters: 100, interval: 2),
            "a segment at the cycling plausibility boundary should be accepted"
        )
        expect(
            !WorkoutRouteSegmentFilter.accepts(distanceMeters: 101, interval: 2),
            "an implausibly fast route segment should be rejected"
        )
        expect(
            !WorkoutRouteSegmentFilter.accepts(distanceMeters: 1, interval: 0),
            "a route segment with a nonpositive interval should be rejected"
        )
        expect(
            !WorkoutRouteSegmentFilter.accepts(distanceMeters: .infinity, interval: 1),
            "a non-finite route segment should be rejected"
        )

        let limit = WorkoutRouteQueuePolicy.maximumPendingPointCount
        expect(
            WorkoutRouteQueuePolicy.canAppend(currentCount: limit - 1, incomingCount: 1),
            "the route queue should accept exactly its configured bound"
        )
        expect(
            !WorkoutRouteQueuePolicy.canAppend(currentCount: limit, incomingCount: 1),
            "the route queue must reject points beyond its configured bound"
        )
        expect(
            !WorkoutRouteQueuePolicy.canAppend(currentCount: Int.max, incomingCount: 1),
            "route queue count overflow must fail closed"
        )

        var queue = WorkoutRouteBatchQueue<Int>()
        expect(
            queue.append(contentsOf: Array(0..<45)),
            "production route queue should accept a bounded burst"
        )
        let firstBatch = queue.takeNextBatch()
        let secondBatch = queue.takeNextBatch()
        let thirdBatch = queue.takeNextBatch()
        expect(firstBatch == Array(0..<20), "first route insertion batch should contain 20 points")
        expect(secondBatch == Array(20..<40), "second route insertion batch should preserve order")
        expect(thirdBatch == Array(40..<45), "final route insertion batch should contain the remainder")
        queue.markInserted(count: firstBatch.count)
        queue.markInserted(count: secondBatch.count)
        queue.markInserted(count: thirdBatch.count)
        expect(queue.insertedPointCount == 45, "successful route batches should count exactly once")
        expect(queue.isEmpty, "draining should leave no pending route points")

        queue.reset()
        expect(
            queue.append(
                contentsOf: Array(
                    0..<WorkoutRouteQueuePolicy.maximumPendingPointCount
                )
            ),
            "queue should accept exactly the backpressure bound"
        )
        expect(
            !queue.append(contentsOf: [999]),
            "queue should reject a point beyond the backpressure bound"
        )
        queue.markFailed()
        expect(queue.hasFailed && queue.isEmpty, "insertion failure should purge pending raw points")

        var generation = WorkoutRouteGenerationGate()
        let firstGeneration = generation.advance()
        expect(generation.accepts(firstGeneration), "current route generation should be accepted")
        _ = generation.advance()
        expect(
            !generation.accepts(firstGeneration),
            "reset route generation must reject an older async insertion completion"
        )
        var wrappingGeneration = WorkoutRouteGenerationGate(current: UInt64.max)
        expect(wrappingGeneration.advance() == 1, "generation rollover must avoid zero reuse")
    }

    private mutating func testRouteRecoveryDistanceAndAssociatedFinalizationPolicies() {
        expect(
            WorkoutRouteFallbackPolicy.canProvideTotal(
                mayContainExistingRouteData: false
            ),
            "a new route may provide a whole-workout fallback distance"
        )
        expect(
            !WorkoutRouteFallbackPolicy.canProvideTotal(
                mayContainExistingRouteData: true
            ),
            "a recovered route must not publish a partial distance as the total"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 1,
                routeSavingFailed: false,
                mayContainExistingRouteData: false
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: true,
                routeStatus: .present
            ),
            "known nonempty associated route should finalize and be reported present"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 0,
                routeSavingFailed: false,
                mayContainExistingRouteData: false
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: false,
                routeStatus: .unavailable
            ),
            "known empty new route should be discarded before workout finalization"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 0,
                routeSavingFailed: false,
                mayContainExistingRouteData: true
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: true,
                routeStatus: .unknown
            ),
            "recovery should preserve a possibly-existing route without claiming it exists"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 20,
                routeSavingFailed: true,
                mayContainExistingRouteData: true
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: true,
                routeStatus: .unknown
            ),
            "a recovered route failure must preserve possible pre-crash data without claiming presence"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 20,
                routeSavingFailed: true,
                mayContainExistingRouteData: false
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: false,
                routeStatus: .unavailable
            ),
            "a failed new route must be discarded and reported unavailable"
        )

        var distance = WorkoutRouteDistanceAccumulator(
            mayContainExistingRouteData: false
        )
        distance.appendPoint(segmentDistanceFromPrevious: nil)
        distance.appendPoint(segmentDistanceFromPrevious: 100)
        distance.appendPoint(segmentDistanceFromPrevious: 50)
        expect(
            distance.totalMeters == 150,
            "two internal segments in the first delivered batch must both count"
        )
        distance.breakSegment()
        distance.appendPoint(segmentDistanceFromPrevious: nil)
        expect(
            distance.totalMeters == 150,
            "first point after pause must not bridge distance across the pause"
        )
        distance.appendPoint(segmentDistanceFromPrevious: 25)
        expect(
            distance.totalMeters == 175,
            "post-resume segments should continue the cumulative total"
        )

        var recoveredDistance = WorkoutRouteDistanceAccumulator(
            mayContainExistingRouteData: true
        )
        recoveredDistance.appendPoint(segmentDistanceFromPrevious: nil)
        recoveredDistance.appendPoint(segmentDistanceFromPrevious: 100)
        expect(
            recoveredDistance.totalMeters == nil,
            "post-recovery segments must remain unavailable as a whole-workout total"
        )

        let endDate = Date(timeIntervalSinceReferenceDate: 800_039_000)
        let terminalDistance = WorkoutTerminalRouteDistancePolicy.candidate(
            distanceMeters: 175,
            capturedAt: endDate
        )
        expect(
            WorkoutMetricPrecedence.cyclingDistance(
                healthKit: nil,
                watchRoute: terminalDistance
            ) == terminalDistance,
            "terminal full snapshot should retain valid route fallback distance"
        )
    }

    private mutating func testRecoverySequenceLeasesNeverReuseReservedValues() {
        var first = WorkoutSequenceLease(after: 0, size: 3)
        expect(first.lowerBound == 1, "first lease should begin after persisted watermark")
        expect(first.persistedHighWatermark == 3, "lease should reserve its full range")
        expect(first.take() == 1, "lease should issue its lower bound")
        expect(first.take() == 2, "lease should remain monotonic")

        var recovered = WorkoutSequenceLease(
            after: first.persistedHighWatermark,
            size: 3
        )
        expect(
            recovered.take() == 4,
            "recovery should skip every value reserved before the crash"
        )
        expect(first.take() == 3, "original lease should issue its final value")
        expect(first.take() == nil, "exhausted lease must not wrap")

        var exhausted = WorkoutSequenceLease(after: UInt64.max, size: 1)
        expect(exhausted.take() == nil, "maximum watermark must not reuse UInt64.max")
    }

    private mutating func testRecoveryStorePersistsIdentityAndLeases() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WorkoutRecoveryTests.\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("active.plist")
        let persistence = WorkoutRecoveryFilePersistence(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSinceReferenceDate: 800_040_000)
        do {
            let firstStore = WatchWorkoutRecoveryStore(persistence: persistence)
            let identity = try firstStore.begin(startDate: start)
            expect(identity.sessionToken != 0, "persisted workout token must be nonzero")
            expect(firstStore.nextSequence() == 1, "first transport sequence should be one")
            let finishRequestedAt = start.addingTimeInterval(90)
            try firstStore.markFinishing(
                disposition: .save,
                requestedAt: finishRequestedAt
            )

            let recoveredStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                recoveredStore.recoveredIdentity?.sessionID == identity.sessionID,
                "relaunch should recover the same workout identity"
            )
            expect(
                recoveredStore.nextSequence() == WorkoutSequenceLease.defaultSize + 1,
                "relaunch must skip the entire pre-crash reserved sequence lease"
            )
            expect(
                recoveredStore.recoveredIdentity?.finishRequest
                    == WatchWorkoutRecoveryStore.FinishRequest(
                        disposition: .save,
                        requestedAt: finishRequestedAt
                    ),
                "relaunch must recover the requested save phase and exact stop date"
            )
            try recoveredStore.markCollectionEnded()
            let collectionEndedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                collectionEndedStore.recoveredIdentity?.finishRequest?.phase
                    == .collectionEnded,
                "collection-ended finalization phase must survive relaunch"
            )
            try collectionEndedStore.markPreparedRoute(.present)
            try collectionEndedStore.markFinishAttempted()
            let finishAttemptedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                finishAttemptedStore.recoveredIdentity?.finishRequest?.phase
                    == .finishAttempted,
                "the pre-call finish-attempt marker must survive relaunch"
            )
            expect(
                finishAttemptedStore.recoveredIdentity?.finishRequest?.routeStatus
                    == .present,
                "known route presence must survive a crash around workout saving"
            )
            try finishAttemptedStore.markFinishFailed()
            let failedFinishStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                failedFinishStore.recoveredIdentity?.finishRequest?.phase
                    == .collectionEnded,
                "an explicit finish callback failure should durably permit one safe retry"
            )
            try failedFinishStore.markFinishAttempted()
            try failedFinishStore.markWorkoutSaved()
            let workoutSavedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                workoutSavedStore.recoveredIdentity?.finishRequest?.phase == .workoutSaved,
                "workout-saved finalization phase must survive relaunch"
            )
            expect(
                try workoutSavedStore.useRecoveredIdentity(
                    startDate: start.addingTimeInterval(1)
                ).sessionID == identity.sessionID,
                "HealthKit start-date jitter within tolerance should retain identity"
            )

            let tombstone = try workoutSavedStore.archiveConfirmedSavedIdentity(
                at: finishRequestedAt
            )
            let archivedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                archivedStore.recoveredIdentity == nil,
                "archiving a confirmed save must release the active identity"
            )
            expect(
                archivedStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                ) == tombstone,
                "a terminal tombstone must survive relaunch and match stable metadata"
            )
            expect(
                tombstone.disposition == .save,
                "legacy saved tombstones must remain explicitly save-only"
            )
            let nextIdentity = try archivedStore.begin(
                startDate: finishRequestedAt.addingTimeInterval(60)
            )
            let combinedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                combinedStore.recoveredIdentity?.sessionID == nextIdentity.sessionID,
                "a new active identity must coexist with an older terminal tombstone"
            )
            expect(
                combinedStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                )?.sessionID == identity.sessionID,
                "starting a new ride must not overwrite late-callback proof"
            )
            try combinedStore.removeTerminalTombstone(sessionID: identity.sessionID)
            let consumedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                consumedStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                ) == nil,
                "late-session cleanup must consume only its matching tombstone"
            )
            expect(
                consumedStore.recoveredIdentity?.sessionID == nextIdentity.sessionID,
                "consuming an old tombstone must preserve the new active identity"
            )

            try consumedStore.clear()
            expect(
                WatchWorkoutRecoveryStore(persistence: persistence).recoveredIdentity == nil,
                "clear should remove the durable workout identity"
            )

            let discardStore = WatchWorkoutRecoveryStore(persistence: persistence)
            let discardIdentity = try discardStore.begin(
                startDate: finishRequestedAt.addingTimeInterval(120)
            )
            try discardStore.markFinishing(
                disposition: .discard,
                requestedAt: finishRequestedAt.addingTimeInterval(150)
            )
            let discardTombstone = try discardStore
                .archiveConfirmedDiscardedIdentity(
                    at: finishRequestedAt.addingTimeInterval(151)
                )
            let reloadedDiscardStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            expect(
                reloadedDiscardStore.terminalTombstone(
                    externalUUID: discardIdentity.sessionID.uuidString
                ) == discardTombstone,
                "a discard tombstone must survive relaunch"
            )
            expect(
                discardTombstone.disposition == .discard
                    && discardTombstone.routeStatus == .unavailable,
                "late discard proof must never imply a saved workout or route"
            )
            try reloadedDiscardStore.removeTerminalTombstone(
                sessionID: discardIdentity.sessionID
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data([0x00, 0x01, 0x02]).write(to: fileURL, options: .atomic)
            let corruptStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                corruptStore.recoveredIdentity == nil,
                "corrupt durable recovery data must fail closed"
            )
            expect(
                corruptStore.loadState == .corrupt,
                "corrupt durable recovery data must remain distinguishable from a missing file"
            )
            do {
                _ = try corruptStore.useRecoveredIdentity(startDate: start)
                expect(false, "recovery must not invent a UUID when HealthKit metadata is absent")
            } catch {
                expect(corruptStore.recoveredIdentity == nil, "failed recovery must retain no identity")
            }
            let builderSessionID = UUID()
            do {
                _ = try corruptStore.useRecoveredIdentity(
                    startDate: start,
                    stableSessionID: builderSessionID
                )
                expect(false, "corrupt state must not be overwritten during identity adoption")
            } catch {
                expect(
                    corruptStore.recoveredIdentity == nil,
                    "corrupt state must stay fail-closed even with a valid builder UUID"
                )
            }
        } catch {
            expect(false, "file-backed recovery fixture threw \(error)")
        }

        struct LegacyFinishRequest: Codable {
            let disposition: WorkoutFinishDisposition
            let requestedAt: Date
        }
        struct LegacyIdentity: Codable {
            let sessionID: UUID
            let sessionToken: UInt16
            let startDate: Date
            let sequenceHighWatermark: UInt64
            let finishRequest: LegacyFinishRequest?
        }
        let legacyPersistence = ControllableRecoveryPersistence()
        do {
            legacyPersistence.data = try PropertyListEncoder().encode(
                LegacyIdentity(
                    sessionID: UUID(),
                    sessionToken: 7,
                    startDate: start,
                    sequenceHighWatermark: 0,
                    finishRequest: LegacyFinishRequest(
                        disposition: .save,
                        requestedAt: start.addingTimeInterval(45)
                    )
                )
            )
            expect(
                WatchWorkoutRecoveryStore(
                    persistence: legacyPersistence
                ).recoveredIdentity?.finishRequest?.phase == .requested,
                "pre-phase recovery files must migrate to requested without data loss"
            )
        } catch {
            expect(false, "legacy recovery migration fixture threw \(error)")
        }

        let controlled = ControllableRecoveryPersistence()
        let controlledStore = WatchWorkoutRecoveryStore(persistence: controlled)
        expect(
            controlledStore.loadState == .missing,
            "an absent recovery file must be reported as missing"
        )
        controlled.failsSave = true
        do {
            _ = try controlledStore.begin(startDate: start)
            expect(false, "identity must not be issued when its durable write fails")
        } catch {
            expect(controlledStore.recoveredIdentity == nil, "failed begin must retain no identity")
        }
        controlled.failsSave = false
        do {
            _ = try controlledStore.begin(startDate: start)
            controlled.failsSave = true
            do {
                try controlledStore.markFinishing(
                    disposition: .discard,
                    requestedAt: start.addingTimeInterval(30)
                )
                expect(false, "finish request must not succeed when persistence fails")
            } catch {
                expect(
                    controlledStore.recoveredIdentity?.finishRequest == nil,
                    "failed finish persistence must not publish a disposition"
                )
            }
            expect(
                controlledStore.nextSequence() == nil,
                "sequence must not be issued when lease reservation cannot be persisted"
            )
            controlled.failsSave = false
            expect(
                controlledStore.nextSequence() == 1,
                "failed reservation must not consume or skip a sequence"
            )
            try controlledStore.markFinishing(
                disposition: .save,
                requestedAt: start.addingTimeInterval(60)
            )
            controlled.failsSave = true
            do {
                try controlledStore.markCollectionEnded()
                expect(false, "phase transition must not publish when persistence fails")
            } catch {
                expect(
                    controlledStore.recoveredIdentity?.finishRequest?.phase == .requested,
                    "failed phase persistence must retain the last durable phase"
                )
            }
            controlled.failsSave = false
            try controlledStore.markCollectionEnded()
            try controlledStore.markFinishAttempted()
            try controlledStore.markWorkoutSaved()
            controlled.failsSave = true
            do {
                _ = try controlledStore.archiveConfirmedSavedIdentity()
                expect(false, "failed tombstone persistence must not release the active identity")
            } catch {
                expect(
                    controlledStore.recoveredIdentity?.finishRequest?.phase == .workoutSaved,
                    "failed tombstone persistence must retain the saved active identity"
                )
                expect(
                    controlledStore.recoveredTerminalTombstones.isEmpty,
                    "failed tombstone persistence must not publish in-memory late-callback proof"
                )
            }
        } catch {
            expect(false, "controlled recovery fixture threw \(error)")
        }
    }

#if WORKOUT_CONTRACT_HOST
    private mutating func testRecoveryStoreSurvivesProcessRelaunch() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WorkoutRecoveryProcessTests.\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("active.plist")
        defer { try? FileManager.default.removeItem(at: directory) }

        func runChild(mode: String) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var environment = ProcessInfo.processInfo.environment
            environment["BIKE_RECOVERY_CHILD_MODE"] = mode
            environment["BIKE_RECOVERY_CHILD_PATH"] = fileURL.path
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (
                process.terminationStatus,
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        do {
            let writeResult = try runChild(mode: "write-and-crash")
            expect(
                writeResult.0 == 0,
                "abrupt recovery writer should exit immediately after reservation: \(writeResult.1)"
            )
            let readResult = try runChild(mode: "read-after-crash")
            let parts = readResult.1.split(separator: "|", omittingEmptySubsequences: false)
            expect(readResult.0 == 0, "post-crash reader should exit cleanly: \(readResult.1)")
            expect(
                parts.count == 2 && UUID(uuidString: String(parts[0])) != nil,
                "post-crash reader should recover a valid identity: \(readResult.1)"
            )
            expect(
                parts.count == 2
                    && UInt64(parts[1]) == WorkoutSequenceLease.defaultSize + 1,
                "post-crash process must skip the full durably reserved lease: \(readResult.1)"
            )
        } catch {
            expect(false, "recovery crash/relaunch child failed: \(error)")
        }
    }
#endif

    private mutating func testWorkoutFormattingKeepsUnavailableValuesDistinctFromZero() {
        expect(WorkoutValueFormatter.heartRate(nil) == "--", "missing heart rate should be unavailable")
        expect(WorkoutValueFormatter.heartRate(0) == "--", "zero heart rate should be unavailable")
        expect(WorkoutValueFormatter.whole(nil) == "--", "missing power should be unavailable")
        expect(WorkoutValueFormatter.whole(0) == "0", "available zero power should remain zero")
        expect(WorkoutValueFormatter.speed(nil) == "--", "missing speed should be unavailable")
        expect(WorkoutValueFormatter.speed(0) == "0.0", "available stopped speed should remain zero")
        expect(WorkoutValueFormatter.distance(nil) == "--", "missing distance should be unavailable")
        expect(WorkoutValueFormatter.distance(0) == "0", "available zero distance should remain zero")
        expect(WorkoutValueFormatter.duration(nil) == "--:--", "missing elapsed time should be unavailable")
        expect(WorkoutValueFormatter.duration(3_661) == "1:01:01", "long duration should retain hours")
        expect(
            WorkoutValueFormatter.duration(Double.greatestFiniteMagnitude) == "596523:14:07",
            "huge finite duration should saturate instead of trapping"
        )
    }

    private func metric(
        _ value: Double,
        _ unit: WorkoutMetricUnitV1,
        _ date: Date,
        _ source: WorkoutMetricSourceV1? = nil
    ) -> WorkoutMetricV1 {
        WorkoutMetricV1(value: value, unit: unit, capturedAt: date, source: source)
    }

    private func makeEnvelope(
        schemaVersion: WorkoutSchemaVersion = .current,
        sessionID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        sessionToken: UInt16 = 1,
        transportGenerationID: UUID? = nil,
        sequence: UInt64,
        capturedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        snapshot: WorkoutSnapshotV1? = nil
    ) -> WorkoutEnvelopeV1 {
        let resolvedSnapshot = snapshot ?? WorkoutSnapshotV1(
            state: .running,
            startDate: capturedAt.addingTimeInterval(-1)
        )
        return WorkoutEnvelopeV1(
            schemaVersion: schemaVersion,
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: sessionToken,
            transportGenerationID: transportGenerationID,
            sequence: sequence,
            capturedAt: capturedAt,
            snapshot: resolvedSnapshot
        )
    }
}

#if WORKOUT_CONTRACT_XCTEST
final class WorkoutContractPlatformTests: XCTestCase {
    func testWorkoutContractSuite() async {
        var suite = WorkoutContractTestSuite()
        await suite.run()
        XCTAssertEqual(suite.failureCount, 0)
    }
}
#else
@main
private enum WorkoutContractTestRunner {
    static func main() async {
#if WORKOUT_CONTRACT_HOST
        if let mode = ProcessInfo.processInfo.environment["BIKE_RECOVERY_CHILD_MODE"],
           let path = ProcessInfo.processInfo.environment["BIKE_RECOVERY_CHILD_PATH"] {
            let persistence = WorkoutRecoveryFilePersistence(
                fileURL: URL(fileURLWithPath: path)
            )
            switch mode {
            case "write-and-crash":
                let store = WatchWorkoutRecoveryStore(persistence: persistence)
                guard (try? store.begin(
                    startDate: Date(timeIntervalSinceReferenceDate: 800_045_000)
                )) != nil,
                store.nextSequence() == 1 else {
                    Darwin._exit(2)
                }
                Darwin._exit(0)
            case "read-after-crash":
                let store = WatchWorkoutRecoveryStore(persistence: persistence)
                guard let identity = store.recoveredIdentity,
                      let sequence = store.nextSequence() else {
                    exit(3)
                }
                print("\(identity.sessionID.uuidString)|\(sequence)")
                return
            default:
                exit(4)
            }
        }
#endif
        var suite = WorkoutContractTestSuite()
        await suite.run()
        guard suite.failureCount == 0 else {
            fputs("Workout contract tests failed: \(suite.failureCount)\n", stderr)
            exit(1)
        }
        print("Workout contract tests passed")
    }
}
#endif
