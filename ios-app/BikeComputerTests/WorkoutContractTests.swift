import Foundation
#if WORKOUT_CONTRACT_XCTEST
import XCTest
#endif

private nonisolated func roundTripWorkoutEnvelope(
    _ envelope: WorkoutEnvelopeV1
) throws -> WorkoutEnvelopeV1 {
    try WorkoutContractCodec.decode(WorkoutContractCodec.encode(envelope))
}

private struct WorkoutContractTestSuite {
    private(set) var failureCount = 0

    mutating func run() {
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
        testSameSessionLifecycleRejectsRegressions()
        testBatchPublishesOnlyLatestCoherentSnapshot()
        testBatchSkipsInvalidItemsAndContinues()
        testOlderSessionCannotReplaceNewerActiveSession()
        testActiveSessionReplacesIdlePlaceholderRegardlessOfDeliveryOrder()
        testActiveSessionReplacesFailedAttemptRegardlessOfDeliveryOrder()
        testEndedSessionReplacesOnlyOlderPlaceholders()
        testNewerTerminalSessionReplacesOlderTerminalSession()
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
        expectThrows(.emptySessionID, "empty session ID") {
            try WorkoutContractCodec.validate(emptyIDEnvelope)
        }
        expectThrows(.zeroSessionToken, "zero token") {
            try WorkoutContractCodec.validate(zeroTokenEnvelope)
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
            sequence: sequence,
            capturedAt: capturedAt,
            snapshot: resolvedSnapshot
        )
    }
}

#if WORKOUT_CONTRACT_XCTEST
final class WorkoutContractPlatformTests: XCTestCase {
    func testWorkoutContractSuite() {
        var suite = WorkoutContractTestSuite()
        suite.run()
        XCTAssertEqual(suite.failureCount, 0)
    }
}
#else
@main
private enum WorkoutContractTestRunner {
    static func main() {
        var suite = WorkoutContractTestSuite()
        suite.run()
        guard suite.failureCount == 0 else {
            fputs("Workout contract tests failed: \(suite.failureCount)\n", stderr)
            exit(1)
        }
        print("Workout contract tests passed")
    }
}
#endif
