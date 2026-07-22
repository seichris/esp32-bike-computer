import HealthKit
import WatchConnectivity
import WatchKit

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let workoutManager: WatchWorkoutManager
    private let heartRateZoneSettingsReceiver:
        WatchHeartRateZoneSettingsReceiver

    override init() {
        let workoutManager = WatchWorkoutManager()
        self.workoutManager = workoutManager
        heartRateZoneSettingsReceiver = WatchHeartRateZoneSettingsReceiver(
            applyMaximumHeartRateBPM: { value in
                workoutManager.setMaximumHeartRateBPM(value)
            }
        )
        super.init()
        heartRateZoneSettingsReceiver.activate()
    }

    func handleActiveWorkoutRecovery() {
        workoutManager.handleActiveWorkoutRecovery()
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        workoutManager.handleWorkoutConfiguration(workoutConfiguration)
    }
}

private final class WatchHeartRateZoneSettingsReceiver:
    NSObject,
    WCSessionDelegate
{
    private let applyMaximumHeartRateBPM: @MainActor (Int) -> Void

    init(
        applyMaximumHeartRateBPM: @escaping @MainActor (Int) -> Void
    ) {
        self.applyMaximumHeartRateBPM = applyMaximumHeartRateBPM
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil, activationState == .activated else { return }
        apply(session.receivedApplicationContext)
    }

    func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        apply(applicationContext)
    }

    private func apply(_ applicationContext: [String: Any]) {
        guard let maximumHeartRateBPM = WorkoutHeartRateZoneSyncContext
            .maximumHeartRateBPM(from: applicationContext) else {
            return
        }
        Task { @MainActor [applyMaximumHeartRateBPM] in
            applyMaximumHeartRateBPM(maximumHeartRateBPM)
        }
    }
}
