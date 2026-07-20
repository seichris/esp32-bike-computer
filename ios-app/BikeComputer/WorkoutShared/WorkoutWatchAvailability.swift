import Foundation

nonisolated enum WorkoutWatchAvailabilityV1: Equatable, Sendable {
    case activating
    case unsupported
    case activationFailed
    case noPairedWatch
    case companionAppNotInstalled
    case ready(isReachable: Bool)
}

nonisolated enum WorkoutWatchAvailabilityPolicyV1 {
    static func resolve(
        isSupported: Bool,
        isActivated: Bool,
        activationFailed: Bool = false,
        isPaired: Bool,
        isCompanionAppInstalled: Bool,
        isReachable: Bool
    ) -> WorkoutWatchAvailabilityV1 {
        guard isSupported else { return .unsupported }
        guard !activationFailed else { return .activationFailed }
        guard isActivated else { return .activating }
        guard isPaired else { return .noPairedWatch }
        guard isCompanionAppInstalled else {
            return .companionAppNotInstalled
        }
        return .ready(isReachable: isReachable)
    }
}
