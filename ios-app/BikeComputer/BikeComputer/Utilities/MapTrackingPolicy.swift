import Foundation

enum MapTrackingBehavior: Equatable {
    case follow
    case followWithHeading
}

enum MapTrackingPolicy {
    static func desiredMode(
        isNavigating: Bool,
        isOfflineMapSelectionActive: Bool
    ) -> MapTrackingBehavior? {
        guard !isOfflineMapSelectionActive else { return nil }
        return isNavigating ? .followWithHeading : .follow
    }
}
