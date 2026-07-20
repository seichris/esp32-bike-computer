import Combine
import Foundation
import WatchConnectivity

/// Publishes Apple Watch pairing and companion-app installation state for the
/// iPhone workout start surfaces. Reachability is intentionally informational:
/// HealthKit can wake an installed Watch app even when WatchConnectivity cannot
/// exchange an immediate foreground message.
final class WorkoutWatchAvailabilityMonitor: NSObject, ObservableObject {
    @Published private(set) var availability: WorkoutWatchAvailabilityV1

    private let session: WCSession?
    private var activationFailed = false

    override init() {
        let isSupported: Bool
        if #available(iOS 17.0, *) {
            isSupported = WCSession.isSupported()
        } else {
            isSupported = false
        }
        session = isSupported ? WCSession.default : nil
        availability = WorkoutWatchAvailabilityPolicyV1.resolve(
            isSupported: isSupported,
            isActivated: false,
            isPaired: false,
            isCompanionAppInstalled: false,
            isReachable: false
        )
        super.init()
    }

    func activate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.activate()
            }
            return
        }
        guard let session else {
            publishAvailability()
            return
        }
        activationFailed = false
        session.delegate = self
        session.activate()
        publishAvailability()
    }

    private func publishAvailability() {
        let availability: WorkoutWatchAvailabilityV1
        if let session {
            let isActivated = session.activationState == .activated
            availability = WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: true,
                isActivated: isActivated,
                activationFailed: activationFailed,
                isPaired: isActivated ? session.isPaired : false,
                isCompanionAppInstalled: isActivated
                    ? session.isWatchAppInstalled
                    : false,
                isReachable: isActivated ? session.isReachable : false
            )
        } else {
            availability = .unsupported
        }

        self.availability = availability
    }

    private func refreshOnMain(
        activationFailed: Bool? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let activationFailed {
                self.activationFailed = activationFailed
            }
            self.publishAvailability()
        }
    }
}

extension WorkoutWatchAvailabilityMonitor: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        refreshOnMain(
            activationFailed: error != nil || activationState != .activated
        )
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        refreshOnMain()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        refreshOnMain(activationFailed: false)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        refreshOnMain()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refreshOnMain()
    }
}
