import Foundation

nonisolated enum WorkoutMetricUnitV1: String, Codable, CaseIterable, Sendable {
    case beatsPerMinute
    case kilocalories
    case meters
    case metersPerSecond
    case seconds
    case watts
    case revolutionsPerMinute
}

nonisolated enum WorkoutMetricSourceV1: String, Codable, Hashable, Sendable {
    case healthKit
    case pairedCyclingSensor
    case watchLocation
    case watchRoute
    case iPhoneLocation
    case iPhoneNavigation
    case unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct WorkoutAvailabilityMaskV1: OptionSet, Codable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let elapsedTime = Self(rawValue: 1 << 0)
    static let currentHeartRate = Self(rawValue: 1 << 1)
    static let averageHeartRate = Self(rawValue: 1 << 2)
    static let activeEnergy = Self(rawValue: 1 << 3)
    static let cyclingDistance = Self(rawValue: 1 << 4)
    static let currentSpeed = Self(rawValue: 1 << 5)
    static let cyclingPower = Self(rawValue: 1 << 6)
    static let cyclingCadence = Self(rawValue: 1 << 7)
    static let heartRateZone = Self(rawValue: 1 << 8)
    static let location = Self(rawValue: 1 << 9)
    static let altitude = Self(rawValue: 1 << 10)
}
