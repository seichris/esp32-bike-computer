import Combine
import CoreLocation
import Foundation
import HealthKit

enum WatchWorkoutSetupState: Equatable {
    case checking
    case needsAuthorization
    case authorizing
    case ready
    case denied
    case unavailable
    case failed
}

enum WatchWorkoutFinishRequestError: Equatable {
    case persistenceFailed
    case saveFailed
    case reconciliationFailed
    case identityMetadataFailed
}

struct WatchWorkoutSummary: Equatable {
    enum Outcome: Equatable {
        case saved
        case discarded
    }

    let outcome: Outcome
    let endedAt: Date
    let duration: TimeInterval?
    let distanceMeters: Double?
    let activeEnergyKilocalories: Double?
    let averageHeartRate: Double?
    let routeStatus: WorkoutRouteSaveStatus
}

struct RecoveredSaveResolution {
    let action: WorkoutRecoveredSaveAction
    let workout: HKWorkout?
}

struct WatchRecoveredWorkoutIdentityAdapter {
    let metadata: () -> [String: Any]
    let startDate: Date
    let sessionState: () -> HKWorkoutSessionState
    let endDate: () -> Date?
    let attachMetadata: ([String: Any]) async throws -> Void

    init(
        metadata: @escaping () -> [String: Any],
        startDate: Date,
        sessionState: @escaping () -> HKWorkoutSessionState,
        endDate: @escaping () -> Date? = { nil },
        attachMetadata: @escaping ([String: Any]) async throws -> Void
    ) {
        self.metadata = metadata
        self.startDate = startDate
        self.sessionState = sessionState
        self.endDate = endDate
        self.attachMetadata = attachMetadata
    }
}

struct WatchRecoveredDiscardSessionAdapter {
    let stopSession: (Date) -> Void
    let finalizeStoppedSession: (Date) -> Void
}

struct WatchRecoveredDiscardFinalizationAdapter {
    let metadata: () -> [String: Any]
    let discardWorkout: () -> Void
    let discardRoute: () -> Void
    let endSession: () -> Void

    init(
        metadata: @escaping () -> [String: Any] = { [:] },
        discardWorkout: @escaping () -> Void,
        discardRoute: @escaping () -> Void,
        endSession: @escaping () -> Void
    ) {
        self.metadata = metadata
        self.discardWorkout = discardWorkout
        self.discardRoute = discardRoute
        self.endSession = endSession
    }
}

struct WatchRecoveredSaveRuntimeAdapter {
    let session: HKWorkoutSession
    let builder: HKLiveWorkoutBuilder
    let sessionState: () -> HKWorkoutSessionState
    let externalUUID: (() -> String?)?
    let builderCollectionEnded: (() -> Bool)?

    init(
        session: HKWorkoutSession,
        builder: HKLiveWorkoutBuilder,
        sessionState: @escaping () -> HKWorkoutSessionState,
        externalUUID: (() -> String?)? = nil,
        builderCollectionEnded: (() -> Bool)? = nil
    ) {
        self.session = session
        self.builder = builder
        self.sessionState = sessionState
        self.externalUUID = externalUUID
        self.builderCollectionEnded = builderCollectionEnded
    }
}

/// The only transitions available while retiring a terminal-tombstoned
/// HealthKit session. The adapter exposes no builder-save API; a retained
/// discard disposition is handled by the completion path only.
struct WatchTerminalSessionCleanupAdapter {
    let stopSession: (Date) -> Void
    let completeSession: (WorkoutFinishDisposition) -> Void
}

/// Testable production boundary for a recovered HealthKit session that may
/// already have a terminal tombstone. It intentionally exposes no save API.
struct WatchRecoveredTerminalSessionAdapter {
    let metadata: () -> [String: Any]
    let startDate: Date?
    let sessionState: () -> HKWorkoutSessionState
    let attachRuntime: () -> Void
    let stopSession: (Date) -> Void
    let discardWorkout: () -> Void
    let endSession: () -> Void
    let releaseSession: () -> Void
}

struct WatchWorkoutSetupProgress: Equatable {
    private(set) var collectionStarted = false
    private(set) var identityMetadataAttached = false

    var canFinalize: Bool {
        collectionStarted && identityMetadataAttached
    }

    mutating func markCollectionStarted() {
        collectionStarted = true
    }

    mutating func markIdentityMetadataAttached() {
        guard collectionStarted else { return }
        identityMetadataAttached = true
    }
}

enum WatchWorkoutIdentityMetadataOutcome {
    case ready
    case failStart(Error)
    case retainForFinishRetry(Error)
}

/// Owns the asynchronous identity-metadata boundary. The lifecycle is read
/// only after the HealthKit call completes, so a quick End action that occurs
/// while that call is suspended cannot be mistaken for an ordinary startup
/// failure.
struct WatchWorkoutIdentityMetadataCoordinator {
    static func attach(
        collectionStarted: Bool,
        attachMetadata: () async throws -> Void,
        lifecycleState: () -> WorkoutSessionStateV1,
        finishDisposition: () -> WorkoutFinishDisposition?
    ) async -> WatchWorkoutIdentityMetadataOutcome {
        do {
            try await attachMetadata()
            return .ready
        } catch {
            guard collectionStarted,
                  lifecycleState() == .ending else {
                return .failStart(error)
            }
            switch finishDisposition() {
            case .save, .discard:
                return .retainForFinishRetry(error)
            case nil:
                return .failStart(error)
            }
        }
    }
}

struct WatchWorkoutIdentityMetadataRetryAdapter {
    let attachMetadata: () async throws -> Void
    let isContextCurrent: () -> Bool
    let resumeFinalization: () -> Void
}

struct WatchRecoverySignalQueue: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isPendingWhileSessionAttached = false

    mutating func recordSignal(hasAttachedSession: Bool) -> Bool {
        generation &+= 1
        if hasAttachedSession {
            isPendingWhileSessionAttached = true
            return false
        }
        return true
    }

    mutating func consumeAfterSessionRelease() -> Bool {
        guard isPendingWhileSessionAttached else { return false }
        isPendingWhileSessionAttached = false
        return true
    }
}

struct WatchFinishFailureRollbackCoordinator {
    static func persistBeforeRetry(
        isPending: inout Bool,
        markFinishFailed: () throws -> Void
    ) -> Bool {
        guard isPending else { return true }
        do {
            try markFinishFailed()
            isPending = false
            return true
        } catch {
            return false
        }
    }
}

struct WatchTerminalPublicationCoordinator {
    @discardableResult
    static func perform(
        publishTerminal: () -> Bool,
        archiveIdentity: () -> Void
    ) -> Bool {
        guard publishTerminal() else { return false }
        archiveIdentity()
        return true
    }
}

struct WatchRecoveredSaveReconciliationGate: Equatable {
    private(set) var isInProgress = false

    var allowsFinalization: Bool { !isInProgress }

    mutating func begin() -> Bool {
        guard !isInProgress else { return false }
        isInProgress = true
        return true
    }

    mutating func end() {
        isInProgress = false
    }
}

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    @Published private(set) var setupState: WatchWorkoutSetupState = .checking
    @Published private(set) var snapshot = WorkoutSnapshotV1(state: .idle)
    @Published private(set) var latestEnvelope: WorkoutEnvelopeV1?
    @Published private(set) var summary: WatchWorkoutSummary?
    @Published private(set) var locationAuthorizationState: WatchRouteRecorder.AuthorizationState
    @Published private(set) var isRecovering = true
    @Published private(set) var finishRequestError: WatchWorkoutFinishRequestError? = nil
    @Published private(set) var isTerminalArchivePending = false
    @Published private(set) var isTerminalPublicationPending = false

    private let healthStore: HKHealthStore
    private let routeRecorder: WatchRouteRecorder
    private let recoveryStore: WatchWorkoutRecoveryStore
    private let injectedRecoveryOperation: (
        @MainActor () async -> (session: HKWorkoutSession?, error: Error?)
    )?
    private let injectedAuthorizationRequestOperation:
        (@MainActor () async throws -> Void)?
    private let injectedAuthorizationRefreshOperation: (@MainActor () async -> Void)?
    private let injectedAuthorizationRefreshState: WatchWorkoutSetupState?
    private let injectedDetachedRecoveryPause: (@MainActor () async -> Void)?
    private let injectedIdentityMetadataRetryAdapter:
        WatchWorkoutIdentityMetadataRetryAdapter?
    private let injectedRecoveredSaveRuntimeAdapter:
        WatchRecoveredSaveRuntimeAdapter?
    private let injectedRecoveredSaveResolver: (
        @MainActor (
            HKLiveWorkoutBuilder,
            WatchWorkoutRecoveryStore.Identity
        ) async -> RecoveredSaveResolution
    )?
    private let injectedSavedWorkoutLookup: (
        @MainActor (String, Date) async throws -> HKWorkout?
    )?
    private let injectedBuilderElapsedTime:
        (@MainActor (HKLiveWorkoutBuilder?) -> TimeInterval)?
    private let injectedFinalizationClaimObserver:
        ((WorkoutSaveFinalizationMode?) -> Void)?
    private let injectedRecoveredDiscardFinalizationAdapter:
        WatchRecoveredDiscardFinalizationAdapter?
    private var cancellables: Set<AnyCancellable> = []

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var lifecycle = WorkoutLifecycleReducer()
    private var identity: WatchWorkoutRecoveryStore.Identity?
    private var periodicSnapshotTask: Task<Void, Never>?
    private var coalescedSnapshotTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var authoritativeFinalizationEndDate: Date?
    private var isBuilderReadyForFinalization = false
    private var isIdentityMetadataRetryPending = false
    private var requiresRecoveredSaveReconciliation = false
    private var recoveredSaveMode: WorkoutSaveFinalizationMode?
    private var reconciledSavedWorkout: HKWorkout?
    private var preparedRouteForFinalization: WorkoutPreparedRoute?
    private var terminalCleanupSessionID: UUID?
    private var terminalCleanupDisposition: WorkoutFinishDisposition?
    private var confirmedTerminalSummarySessionID: UUID?
    private var confirmedTerminalSnapshot: WorkoutSnapshotV1?
    private var recoverySignalQueue = WatchRecoverySignalQueue()
    private var recoveredSaveReconciliationGate =
        WatchRecoveredSaveReconciliationGate()
    private var isRecoveryLoopRunning = false
    private var isDetachedSaveReconciliationInProgress = false
    private var isFinishFailureRollbackPending = false
    private var lastSnapshotPublishedAt = Date.distantPast
    private var lastErrorCode: WorkoutSafeErrorCodeV1?

    private var currentHeartRate: WorkoutMetricV1?
    private var averageHeartRate: WorkoutMetricV1?
    private var activeEnergy: WorkoutMetricV1?
    private var healthKitDistance: WorkoutMetricCandidate?
    private var pairedSensorSpeed: WorkoutMetricCandidate?
    private var cyclingPower: WorkoutMetricV1?
    private var cyclingCadence: WorkoutMetricV1?
    private var terminalRouteDistance: WorkoutMetricCandidate?

    override convenience init() {
        self.init(
            healthStore: HKHealthStore(),
            routeRecorder: WatchRouteRecorder(),
            recoveryStore: WatchWorkoutRecoveryStore(),
            recoverActiveWorkoutSession: nil,
            requestAuthorization: nil,
            refreshAuthorization: nil,
            authorizationRefreshState: nil,
            pauseDetachedRecovery: nil,
            identityMetadataRetryAdapter: nil,
            recoveredSaveRuntimeAdapter: nil,
            recoveredSaveResolver: nil,
            savedWorkoutLookup: nil,
            builderElapsedTime: nil,
            initialFinishFailureRollbackPending: false,
            finalizationClaimObserver: nil,
            recoveredDiscardFinalizationAdapter: nil,
            initializeOnLaunch: true
        )
    }

    init(
        healthStore: HKHealthStore,
        routeRecorder: WatchRouteRecorder,
        recoveryStore: WatchWorkoutRecoveryStore,
        recoverActiveWorkoutSession: (
            @MainActor () async -> (session: HKWorkoutSession?, error: Error?)
        )? = nil,
        requestAuthorization: (@MainActor () async throws -> Void)? = nil,
        refreshAuthorization: (@MainActor () async -> Void)? = nil,
        authorizationRefreshState: WatchWorkoutSetupState? = nil,
        pauseDetachedRecovery: (@MainActor () async -> Void)? = nil,
        identityMetadataRetryAdapter:
            WatchWorkoutIdentityMetadataRetryAdapter? = nil,
        recoveredSaveRuntimeAdapter:
            WatchRecoveredSaveRuntimeAdapter? = nil,
        recoveredSaveResolver: (
            @MainActor (
                HKLiveWorkoutBuilder,
                WatchWorkoutRecoveryStore.Identity
            ) async -> RecoveredSaveResolution
        )? = nil,
        savedWorkoutLookup: (
            @MainActor (String, Date) async throws -> HKWorkout?
        )? = nil,
        builderElapsedTime:
            (@MainActor (HKLiveWorkoutBuilder?) -> TimeInterval)? = nil,
        initialFinishFailureRollbackPending: Bool = false,
        finalizationClaimObserver:
            ((WorkoutSaveFinalizationMode?) -> Void)? = nil,
        recoveredDiscardFinalizationAdapter:
            WatchRecoveredDiscardFinalizationAdapter? = nil,
        initializeOnLaunch: Bool = true
    ) {
        self.healthStore = healthStore
        self.routeRecorder = routeRecorder
        self.recoveryStore = recoveryStore
        self.injectedRecoveryOperation = recoverActiveWorkoutSession
        self.injectedAuthorizationRequestOperation = requestAuthorization
        self.injectedAuthorizationRefreshOperation = refreshAuthorization
        self.injectedAuthorizationRefreshState = authorizationRefreshState
        self.injectedDetachedRecoveryPause = pauseDetachedRecovery
        self.injectedIdentityMetadataRetryAdapter = identityMetadataRetryAdapter
        self.injectedRecoveredSaveRuntimeAdapter = recoveredSaveRuntimeAdapter
        self.injectedRecoveredSaveResolver = recoveredSaveResolver
        self.injectedSavedWorkoutLookup = savedWorkoutLookup
        self.injectedBuilderElapsedTime = builderElapsedTime
        self.injectedFinalizationClaimObserver = finalizationClaimObserver
        self.injectedRecoveredDiscardFinalizationAdapter =
            recoveredDiscardFinalizationAdapter
        self.locationAuthorizationState = routeRecorder.authorizationState
        super.init()

        if let recoveredSaveRuntimeAdapter {
            session = recoveredSaveRuntimeAdapter.session
            builder = recoveredSaveRuntimeAdapter.builder
            isBuilderReadyForFinalization = true
        }
        isFinishFailureRollbackPending = initialFinishFailureRollbackPending
        if initialFinishFailureRollbackPending {
            finishRequestError = .saveFailed
        }

        routeRecorder.$authorizationState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.locationAuthorizationState = state
            }
            .store(in: &cancellables)

        if initializeOnLaunch {
            Task { [weak self] in
                await self?.initialize()
            }
        } else {
            isRecovering = false
        }
    }

    deinit {
        periodicSnapshotTask?.cancel()
        coalescedSnapshotTask?.cancel()
        finalizationTask?.cancel()
    }

    var state: WorkoutSessionStateV1 { lifecycle.state }
    var isWorkoutActive: Bool { lifecycle.state.isActive }
    var isAwaitingDetachedSessionCleanup: Bool {
        if isTerminalPublicationPending { return true }
        guard session == nil else { return false }
        return isTerminalArchivePending
            || recoveryStore.recoveredIdentity?.finishRequest?.disposition == .discard
            || recoveryStore.recoveredIdentity?.finishRequest?.phase == .workoutSaved
            || reconciledSavedWorkout != nil
    }
    var isDiscarding: Bool {
        lifecycle.state == .ending && lifecycle.finishDisposition == .discard
    }
    var hasCorruptRecoveryState: Bool {
        recoveryStore.loadState == .corrupt
    }
    var hasUnavailableRecoveryState: Bool {
        recoveryStore.loadState == .unavailable
    }
    var hasPendingWorkoutRecovery: Bool {
        recoveryStore.recoveredIdentity != nil
    }

    func requestAuthorization() {
        Task { [weak self] in
            await self?.authorizeHealthKit()
        }
    }

    func retrySetup() {
        guard WorkoutRecoverySingleFlightPolicy.canStartRetry(
            isWorkoutActive: isWorkoutActive,
            isRecovering: isRecovering
        ) else { return }
        isRecovering = true
        setupState = .checking
        Task { [weak self] in
            await self?.initialize()
        }
    }

    func confirmResetCorruptRecovery() {
        guard !isWorkoutActive,
              session == nil,
              !isRecovering,
              recoveryStore.loadState == .corrupt else {
            return
        }
        do {
            try recoveryStore.quarantineCorruptState()
        } catch {
            setupState = .failed
            return
        }
        retrySetup()
    }

    func handleActiveWorkoutRecovery() {
        guard recoverySignalQueue.recordSignal(
            hasAttachedSession: session != nil
        ) else { return }
        startRecoveryLoopIfNeeded()
    }

    func startOutdoorCycling() {
        Task { [weak self] in
            await self?.startOutdoorCyclingWorkout()
        }
    }

    func pause() {
        guard lifecycle.state == .running else { return }
        session?.pause()
    }

    func resume() {
        guard lifecycle.state == .paused else { return }
        session?.resume()
    }

    func endAndSave() {
        requestEnd(.save, explicitRiderChoice: true)
    }

    func discard() {
        requestEnd(.discard, explicitRiderChoice: true)
    }

    func retryFinalization() {
        guard finishRequestError == .reconciliationFailed
                || finishRequestError == .saveFailed
                || finishRequestError == .identityMetadataFailed,
              lifecycle.state == .ending,
              finalizationTask == nil else {
            return
        }
        finishRequestError = nil
        Task { [weak self] in
            guard let self else { return }
            if isIdentityMetadataRetryPending {
                await retryIdentityMetadataAttachmentForFinalization()
            } else if lifecycle.finishDisposition == .discard,
                      session != nil
                        || injectedRecoveredDiscardFinalizationAdapter != nil {
                beginFinalizationAfterStop(
                    at: recoveryStore.recoveredIdentity?.finishRequest?.requestedAt
                        ?? Date()
                )
            } else if session == nil {
                if lifecycle.finishDisposition == .discard {
                    finishRequestError = .reconciliationFailed
                    handleActiveWorkoutRecovery()
                } else {
                    await reconcileDetachedSave()
                }
            } else {
                await resumeRecoveredStoppedSaveFinalization()
            }
        }
    }

    func dismissSummary() {
        guard !isAwaitingDetachedSessionCleanup else { return }
        guard lifecycle.apply(.reset) else { return }
        finishRequestError = nil
        summary = nil
        snapshot = WorkoutSnapshotV1(state: .idle)
        latestEnvelope = nil
        routeRecorder.discardRoute()
        clearMetrics()
    }

    func retryDetachedSessionCleanup() {
        guard isAwaitingDetachedSessionCleanup else { return }
        if isTerminalPublicationPending {
            retryTerminalPublicationAndArchive()
            return
        }
        if isTerminalArchivePending {
            guard let request = recoveryStore.recoveredIdentity?.finishRequest else {
                finishRequestError = .reconciliationFailed
                return
            }
            switch request.disposition {
            case .save:
                archiveConfirmedSave(at: summary?.endedAt ?? Date())
            case .discard:
                archiveConfirmedDiscard(at: summary?.endedAt ?? Date())
            }
            if isTerminalArchivePending {
                finishRequestError = .reconciliationFailed
            } else {
                finishRequestError = nil
            }
            return
        }
        handleActiveWorkoutRecovery()
    }

    private func startRecoveryLoopIfNeeded() {
        guard !isRecovering, session == nil else { return }
        isRecovering = true
        setupState = .checking
        Task { [weak self] in
            await self?.initialize()
        }
    }

    private func handleAttachedSessionRelease() {
        guard session == nil,
              recoverySignalQueue.consumeAfterSessionRelease() else {
            return
        }
        if !isRecoveryLoopRunning {
            isRecovering = false
            startRecoveryLoopIfNeeded()
        }
    }

    private func initialize() async {
        isRecoveryLoopRunning = true
        defer { isRecoveryLoopRunning = false }
        guard HKHealthStore.isHealthDataAvailable() else {
            setupState = .unavailable
            isRecovering = false
            return
        }
        recoveryStore.reload()
        guard [.missing, .valid].contains(recoveryStore.loadState) else {
            // Unknown bytes may contain a discard request, a commit-unknown
            // save, or terminal tombstones. Never clear or begin over them.
            setupState = .failed
            isRecovering = false
            return
        }

        while true {
            let requestGeneration = recoverySignalQueue.generation
            let recoveryOutcome = await recoverActiveWorkoutIfPresent()
            if requestGeneration != recoverySignalQueue.generation,
               session == nil {
                continue
            }
            if WorkoutRecoveryInitializationPolicy.shouldClearDurableIdentity(
                after: recoveryOutcome
            ) {
                await refreshAuthorizationState()
                guard requestGeneration == recoverySignalQueue.generation else {
                    continue
                }
                if recoveryStore.hasCorruptResetProtection,
                   recoveryStore.recoveredIdentity != nil {
                    // A separate corrupt-reset authorization may coexist with
                    // a newer ordinary ride. A nil query is not permission to
                    // expose Start while that ride can still arrive through a
                    // late watchOS recovery callback.
                    setupState = .failed
                } else if !recoveryStore.hasCorruptResetProtection {
                    do {
                        try recoveryStore.clear()
                    } catch {
                        setupState = .failed
                    }
                }
            } else if recoveryOutcome == .failed {
                setupState = .failed
            }
            break
        }
        isRecovering = terminalCleanupSessionID != nil
    }

    private func refreshAuthorizationState() async {
        if let injectedAuthorizationRefreshOperation {
            await injectedAuthorizationRefreshOperation()
            if let injectedAuthorizationRefreshState {
                setupState = injectedAuthorizationRefreshState
            }
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            setupState = .unavailable
            return
        }

        let shareStatuses = Self.typesToShare.map(healthStore.authorizationStatus(for:))
        if shareStatuses.contains(.sharingDenied) {
            setupState = .denied
            return
        }

        do {
            let status = try await authorizationRequestStatus()
            setupState = Self.resolveSetupState(
                shareStatuses: shareStatuses,
                requestStatus: status
            ) ?? .failed
        } catch {
            setupState = .failed
        }
    }

    private func authorizeHealthKit() async {
        guard !isWorkoutActive else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            setupState = .unavailable
            return
        }
        setupState = .authorizing
        do {
            if let injectedAuthorizationRequestOperation {
                try await injectedAuthorizationRequestOperation()
            } else {
                try await healthStore.requestAuthorization(
                    toShare: Self.typesToShare,
                    read: Self.typesToRead
                )
                routeRecorder.requestAuthorizationIfNeeded()
            }
            await refreshAuthorizationState()
        } catch {
            setupState = Self.isAuthorizationError(error) ? .denied : .failed
        }
    }

    func startOutdoorCyclingWorkout() async {
        let admissionRecoveryGeneration = recoverySignalQueue.generation
        guard !isRecovering,
              !isWorkoutActive,
              session == nil,
              !isAwaitingDetachedSessionCleanup else {
            return
        }
        guard !hasPendingWorkoutRecovery else {
            setupState = .failed
            return
        }
        if setupState != .ready {
            await authorizeHealthKit()
        }
        guard setupState == .ready,
              admissionRecoveryGeneration == recoverySignalQueue.generation,
              !isRecovering,
              !isWorkoutActive,
              session == nil,
              !isAwaitingDetachedSessionCleanup,
              !hasPendingWorkoutRecovery else {
            return
        }
        guard lifecycle.apply(.requestStart) else { return }

        summary = nil
        finishRequestError = nil
        clearMetrics()
        lastErrorCode = nil
        isBuilderReadyForFinalization = false
        isIdentityMetadataRetryPending = false
        requiresRecoveredSaveReconciliation = false
        isTerminalPublicationPending = false
        preparedRouteForFinalization = nil
        let startDate = Date()

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor

        do {
            identity = try recoveryStore.begin(startDate: startDate)
            let session = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder
            let routeBuilder = builder.seriesBuilder(
                for: HKSeriesType.workoutRoute()
            ) as? HKWorkoutRouteBuilder
            routeRecorder.begin(
                routeBuilder: routeBuilder,
                startDate: startDate
            ) { [weak self] in
                self?.scheduleCoalescedSnapshot()
            }
            publishSnapshotImmediately()

            session.startActivity(with: startDate)
            var setupProgress = WatchWorkoutSetupProgress()
            do {
                try await builder.beginCollection(at: startDate)
                setupProgress.markCollectionStarted()
            } catch {
                // No builder collection exists, even if the asynchronous
                // session-running callback arrived first. Saving is invalid.
                handleStartFailure(error)
                return
            }
            guard let identity else {
                handleStartFailure(WorkoutFinalizationError.managerReleased)
                return
            }
            let metadataOutcome = await WatchWorkoutIdentityMetadataCoordinator.attach(
                collectionStarted: setupProgress.collectionStarted,
                attachMetadata: {
                    try await builder.addMetadata(
                        Self.workoutIdentityMetadata(sessionID: identity.sessionID)
                    )
                },
                lifecycleState: { [weak self] in
                    self?.lifecycle.state ?? .failed
                },
                finishDisposition: { [weak self] in
                    self?.lifecycle.finishDisposition
                }
            )
            guard self.builder === builder,
                  self.session === session else {
                return
            }
            switch metadataOutcome {
            case .ready:
                setupProgress.markIdentityMetadataAttached()
                isIdentityMetadataRetryPending = false
            case .failStart(let error):
                handleStartFailure(error)
                return
            case .retainForFinishRetry(let error):
                // The user's durable finish request wins over startup cleanup.
                // Keep the collected builder, stopped session, route, and
                // identity intact until metadata attachment can be retried.
                guard retainCollectedFinishForIdentityMetadataRetry(error) else {
                    handleStartFailure(error)
                    return
                }
                return
            }
            guard self.builder === builder,
                  self.session === session,
                  lifecycle.state.isActive else {
                return
            }
            isBuilderReadyForFinalization = setupProgress.canFinalize
            if lifecycle.state == .ending {
                stopSessionForFinalization(
                    session,
                    at: authoritativeFinalizationEndDate ?? Date()
                )
            }
        } catch {
            handleStartFailure(error)
        }
    }

    /// Applies the manager-level retention contract used by the suspended
    /// metadata-attachment catch. Kept internal so the Watch test target can
    /// prove that the durable finish request and ending lifecycle survive.
    @discardableResult
    func retainCollectedFinishForIdentityMetadataRetry(_ error: Error?) -> Bool {
        guard lifecycle.state == .ending,
              let disposition = lifecycle.finishDisposition,
              recoveryStore.recoveredIdentity?.finishRequest?.disposition
                == disposition else {
            return false
        }
        isIdentityMetadataRetryPending = true
        isBuilderReadyForFinalization = false
        finishRequestError = .identityMetadataFailed
        lastErrorCode = Self.safeErrorCode(for: error)
        publishSnapshotImmediately()
        return true
    }

    private func requestEnd(
        _ disposition: WorkoutFinishDisposition,
        requestedAt: Date = Date(),
        explicitRiderChoice: Bool = false
    ) {
        guard [.starting, .running, .paused].contains(lifecycle.state) else { return }
        guard persistFinishRequest(
            disposition: disposition,
            requestedAt: requestedAt,
            explicitRiderChoice: explicitRiderChoice
        ) else { return }
        guard let durableDisposition = recoveryStore.recoveredIdentity?
                .finishRequest?.disposition,
              lifecycle.apply(.requestEnd(durableDisposition)) else { return }
        authoritativeFinalizationEndDate = requestedAt
        routeRecorder.stopLocationUpdates()
        publishSnapshotImmediately()
        if let session {
            stopSessionForFinalization(session, at: requestedAt)
        } else {
            handleStartFailure(nil)
        }
    }

    @discardableResult
    func persistFinishRequest(
        disposition: WorkoutFinishDisposition,
        requestedAt: Date,
        explicitRiderChoice: Bool = true
    ) -> Bool {
        do {
            try recoveryStore.markFinishing(
                disposition: disposition,
                requestedAt: requestedAt,
                explicitRiderChoice: explicitRiderChoice
            )
            finishRequestError = nil
            return true
        } catch {
            finishRequestError = .persistenceFailed
            return false
        }
    }

    private func stopSessionForFinalization(
        _ workoutSession: HKWorkoutSession,
        at requestedAt: Date
    ) {
        authoritativeFinalizationEndDate = authoritativeFinalizationEndDate ?? requestedAt
        switch workoutSession.state {
        case .stopped, .ended:
            beginFinalizationAfterStop(
                at: workoutSession.endDate ?? requestedAt
            )
        case .notStarted, .prepared, .running, .paused:
            workoutSession.stopActivity(with: requestedAt)
        @unknown default:
            workoutSession.stopActivity(with: requestedAt)
        }
    }

    private func handleStartFailure(_ error: Error?) {
        finishRequestError = nil
        periodicSnapshotTask?.cancel()
        periodicSnapshotTask = nil
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        let failedSession = session
        routeRecorder.discardRoute()
        builder?.discardWorkout()
        failedSession?.end()
        session = nil
        builder = nil
        isBuilderReadyForFinalization = false
        isIdentityMetadataRetryPending = false
        requiresRecoveredSaveReconciliation = false
        isTerminalPublicationPending = false
        isFinishFailureRollbackPending = false
        isTerminalArchivePending = false
        lastErrorCode = Self.safeErrorCode(for: error)
        if lastErrorCode == .authorizationDenied {
            setupState = .denied
        }
        _ = lifecycle.apply(.fail)
        publishFailureSnapshot()
        identity = nil
        try? recoveryStore.clear()
        handleAttachedSessionRelease()
    }

    private func retryIdentityMetadataAttachmentForFinalization() async {
        guard lifecycle.state == .ending,
              let disposition = lifecycle.finishDisposition,
              let durableIdentity = recoveryStore.recoveredIdentity ?? identity,
              durableIdentity.finishRequest?.disposition == disposition else {
            finishRequestError = .reconciliationFailed
            return
        }

        if let injectedIdentityMetadataRetryAdapter {
            await performIdentityMetadataRetry(
                durableIdentity: durableIdentity,
                adapter: injectedIdentityMetadataRetryAdapter
            )
            return
        }

        guard let workoutSession = session,
              let workoutBuilder = builder else {
            finishRequestError = .reconciliationFailed
            return
        }

        await performIdentityMetadataRetry(
            durableIdentity: durableIdentity,
            adapter: WatchWorkoutIdentityMetadataRetryAdapter(
                attachMetadata: {
                    try await workoutBuilder.addMetadata(
                        Self.workoutIdentityMetadata(
                            sessionID: durableIdentity.sessionID
                        )
                    )
                },
                isContextCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.session === workoutSession
                        && self.builder === workoutBuilder
                        && self.lifecycle.state == .ending
                        && self.lifecycle.finishDisposition == disposition
                },
                resumeFinalization: { [weak self] in
                    guard let self else { return }
                    self.stopSessionForFinalization(
                        workoutSession,
                        at: self.authoritativeFinalizationEndDate
                            ?? workoutSession.endDate
                            ?? durableIdentity.finishRequest?.requestedAt
                            ?? Date()
                    )
                }
            )
        )
    }

    private func performIdentityMetadataRetry(
        durableIdentity: WatchWorkoutRecoveryStore.Identity,
        adapter: WatchWorkoutIdentityMetadataRetryAdapter
    ) async {
        do {
            try await adapter.attachMetadata()
            guard adapter.isContextCurrent() else {
                return
            }
            identity = recoveryStore.recoveredIdentity ?? durableIdentity
            isIdentityMetadataRetryPending = false
            isBuilderReadyForFinalization = true
            finishRequestError = nil
            lastErrorCode = nil
            adapter.resumeFinalization()
        } catch {
            guard adapter.isContextCurrent() else {
                return
            }
            _ = retainCollectedFinishForIdentityMetadataRetry(error)
        }
    }

    private func recoverActiveWorkoutIfPresent() async -> WorkoutRecoveryAttemptOutcome {
        let result = await recoverActiveWorkoutSession()
        if result.error != nil {
            return .failed
        }
        guard let recoveredSession = result.session else {
            return await recoverDetachedFinalizationIfPresent()
        }
        guard recoveredSession.type == .primary else { return .none }
        if session == nil, lifecycle.state == .ending {
            lifecycle = WorkoutLifecycleReducer()
            finishRequestError = nil
        }
        let wasEndedBeforeMetadataRepair = recoveredSession.state == .ended

        let recoveredBuilder = recoveredSession.associatedWorkoutBuilder()
        if let terminalOutcome = recoverTerminalTombstoneSessionIfPresent(
            using: WatchRecoveredTerminalSessionAdapter(
                metadata: { recoveredBuilder.metadata },
                startDate: recoveredSession.startDate,
                sessionState: { recoveredSession.state },
                attachRuntime: { [weak self] in
                    guard let self else { return }
                    recoveredSession.delegate = self
                    self.session = recoveredSession
                    self.builder = recoveredBuilder
                },
                stopSession: { date in
                    recoveredSession.stopActivity(with: date)
                },
                discardWorkout: {
                    recoveredBuilder.discardWorkout()
                },
                endSession: {
                    recoveredSession.end()
                },
                releaseSession: { [weak self] in
                    guard let self, self.session === recoveredSession else {
                        return
                    }
                    self.session = nil
                    self.builder = nil
                }
            )
        ) {
            return terminalOutcome
        }
        recoveredBuilder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: recoveredSession.workoutConfiguration
        )

        let startDate = recoveredSession.startDate
            ?? recoveryStore.recoveredIdentity?.startDate
            ?? Date()
        guard var recoveredIdentity = await recoverWorkoutIdentity(
            using: WatchRecoveredWorkoutIdentityAdapter(
                metadata: { recoveredBuilder.metadata },
                startDate: startDate,
                sessionState: { recoveredSession.state },
                endDate: { recoveredSession.endDate },
                attachMetadata: { metadata in
                    try await recoveredBuilder.addMetadata(metadata)
                }
            )
        ) else {
            return .failed
        }
        let isEndedAfterMetadataRepair = recoveredSession.state == .ended
        recoveredSession.delegate = self
        recoveredBuilder.delegate = self
        let recoveredState = recoveredSession.state
        let adoptionAction = WorkoutRecoveredSessionAdoptionPolicy.action(
            wasEndedBeforeMetadataRepair: wasEndedBeforeMetadataRepair,
            isEndedAfterMetadataRepair: isEndedAfterMetadataRepair,
            isStoppedAfterMetadataRepair: recoveredState == .stopped,
            pendingDisposition: recoveredIdentity.finishRequest?.disposition
        )
        if [.stopped, .ended].contains(recoveredState),
           recoveredIdentity.finishRequest == nil {
            let disposition: WorkoutFinishDisposition
            if recoveredIdentity.corruptResetPendingFinishChoice == true {
                disposition = .discard
            } else {
                switch adoptionAction {
                case .adoptStopped(let terminalDisposition),
                     .adoptEnded(let terminalDisposition):
                    disposition = terminalDisposition
                case .adopt:
                    disposition = .save
                }
            }
            do {
                try recoveryStore.markFinishing(
                    disposition: disposition,
                    requestedAt: recoveredSession.endDate ?? Date(),
                    explicitRiderChoice: false
                )
                guard let updatedIdentity = recoveryStore.recoveredIdentity else {
                    return .failed
                }
                recoveredIdentity = updatedIdentity
            } catch {
                recoveredSession.delegate = nil
                recoveredBuilder.delegate = nil
                return .failed
            }
        }
        identity = recoveredIdentity
        let recoveredFinishRequest = recoveredIdentity.finishRequest
        session = recoveredSession
        builder = recoveredBuilder
        isBuilderReadyForFinalization = true
        isIdentityMetadataRetryPending = false
        isTerminalPublicationPending = false
        _ = lifecycle.apply(.requestStart)
        switch recoveredState {
        case .running:
            _ = lifecycle.apply(.sessionRunning)
        case .paused:
            _ = lifecycle.apply(.sessionRunning)
            _ = lifecycle.apply(.sessionPaused)
        case .ended:
            _ = lifecycle.apply(.sessionRunning)
        case .stopped:
            _ = lifecycle.apply(.sessionRunning)
        case .notStarted, .prepared:
            break
        @unknown default:
            handleStartFailure(nil)
            return .failed
        }

        if recoveredState == .stopped {
            _ = lifecycle.apply(
                .requestEnd(recoveredFinishRequest?.disposition ?? .save)
            )
            authoritativeFinalizationEndDate = recoveredSession.endDate
                ?? recoveredFinishRequest?.requestedAt
        } else if let recoveredFinishRequest {
            _ = lifecycle.apply(.requestEnd(recoveredFinishRequest.disposition))
            authoritativeFinalizationEndDate = recoveredFinishRequest.requestedAt
        }

        updateAllMetrics(from: recoveredBuilder, capturedAt: Date())
        setupState = .ready
        publishSnapshotImmediately()

        if [.stopped, .ended].contains(recoveredState),
           (recoveredFinishRequest?.disposition ?? .save) == .save {
            await resumeRecoveredStoppedSaveFinalization()
            return .recovered
        }

        attachRecoveredRouteBuilder(
            recoveredBuilder,
            startDate: startDate
        )
        if lifecycle.state == .paused {
            routeRecorder.setPaused(true, at: Date())
        }
        if lifecycle.state == .ending {
            routeRecorder.stopLocationUpdates()
            let recoveryEndDate = authoritativeFinalizationEndDate
                ?? recoveredSession.endDate
                ?? Date()
            if recoveredIdentity.corruptResetPendingFinishChoice == true,
               recoveredFinishRequest?.disposition == .discard {
                handleRecoveredDiscardSessionState(
                    recoveredState,
                    transitionDate: recoveryEndDate,
                    adapter: WatchRecoveredDiscardSessionAdapter(
                        stopSession: { date in
                            recoveredSession.stopActivity(with: date)
                        },
                        finalizeStoppedSession: { [weak self] date in
                            self?.beginFinalizationAfterStop(at: date)
                        }
                    )
                )
            } else {
                stopSessionForFinalization(
                    recoveredSession,
                    at: recoveryEndDate
                )
            }
        } else {
            startPeriodicSnapshots()
        }
        return .recovered
    }

    func handleRecoveredDiscardSessionState(
        _ state: HKWorkoutSessionState,
        transitionDate: Date,
        adapter: WatchRecoveredDiscardSessionAdapter
    ) {
        switch state {
        case .stopped, .ended:
            adapter.finalizeStoppedSession(transitionDate)
        case .running, .paused, .notStarted, .prepared:
            adapter.stopSession(transitionDate)
        @unknown default:
            adapter.stopSession(transitionDate)
        }
    }

    /// Owns the exact local-store/HealthKit identity adoption boundary used by
    /// active-session recovery. The adapter lets Watch tests execute the
    /// production manager path without synthesizing HealthKit session objects.
    func recoverWorkoutIdentity(
        using adapter: WatchRecoveredWorkoutIdentityAdapter
    ) async -> WatchWorkoutRecoveryStore.Identity? {
        let metadata = adapter.metadata()
        let containsIdentityMetadata = Self.containsWorkoutIdentityMetadata(
            metadata
        )
        let builderSessionID = Self.workoutIdentitySessionID(from: metadata)
        let isCorruptResetAuthorized = recoveryStore
            .authorizesCorruptResetRecovery(startDate: adapter.startDate)
        let resetProtectedIdentity = recoveryStore.recoveredIdentity.map {
            $0.corruptResetPendingFinishChoice == true
                && $0.finishRequest?.disposition == .discard
        } ?? false
        guard !containsIdentityMetadata
                || builderSessionID != nil
                || isCorruptResetAuthorized
                || resetProtectedIdentity else {
            return nil
        }

        let hasDurableIdentity = recoveryStore.recoveredIdentity != nil
        var discardTerminalAt: Date?
        if !hasDurableIdentity {
            // The builder UUID cannot reconstruct a lost finish disposition or
            // terminal tombstones. Ordinary adoption is allowed only when the
            // store was confirmed absent and the HealthKit session is active.
            // A rider-confirmed corrupt reset carries a durable one-shot
            // authorization that additionally permits stopped/ended adoption,
            // but only with a prewritten discard disposition.
            let sessionState = adapter.sessionState()
            if isCorruptResetAuthorized {
                guard [.running, .paused, .stopped, .ended]
                    .contains(sessionState) else {
                    return nil
                }
                if builderSessionID == nil {
                    return try? recoveryStore.useCorruptResetDiscardIdentity(
                        startDate: adapter.startDate,
                        requestedAt: adapter.endDate() ?? Date()
                    )
                }
                if [.stopped, .ended].contains(sessionState) {
                    discardTerminalAt = adapter.endDate() ?? Date()
                } else if !Self.canAdoptRecoveredIdentity(
                    sessionState: sessionState
                ) {
                    return nil
                }
            } else {
                guard recoveryStore.loadState == .missing,
                      builderSessionID != nil,
                      Self.canAdoptRecoveredIdentity(
                          sessionState: sessionState
                      ) else {
                    return nil
                }
            }
        }

        do {
            var recoveredIdentity = try recoveryStore.useRecoveredIdentity(
                startDate: adapter.startDate,
                stableSessionID: builderSessionID,
                discardTerminalAt: discardTerminalAt
            )
            if let builderSessionID {
                guard builderSessionID
                        == (recoveredIdentity.healthKitSessionID
                            ?? recoveredIdentity.sessionID) else {
                    return nil
                }
            } else if resetProtectedIdentity,
                      recoveredIdentity.finishRequest?.disposition == .discard {
                // Rider-authorized metadata-less cleanup deliberately never
                // attaches a synthetic UUID to a builder that will be discarded.
            } else {
                let identityMetadata = Self.workoutIdentityMetadata(
                    sessionID: recoveredIdentity.sessionID
                )
                try await adapter.attachMetadata(identityMetadata)
                guard Self.workoutIdentitySessionID(from: adapter.metadata())
                        == recoveredIdentity.sessionID else {
                    return nil
                }
            }
            if recoveredIdentity.corruptResetPendingFinishChoice == true,
               recoveredIdentity.finishRequest == nil,
               [.stopped, .ended].contains(adapter.sessionState()) {
                try recoveryStore.markFinishing(
                    disposition: .discard,
                    requestedAt: adapter.endDate() ?? Date(),
                    explicitRiderChoice: false
                )
                guard let updatedIdentity = recoveryStore.recoveredIdentity else {
                    return nil
                }
                recoveredIdentity = updatedIdentity
            }
            return recoveredIdentity
        } catch {
            return nil
        }
    }

    private func recoverDetachedFinalizationIfPresent() async -> WorkoutRecoveryAttemptOutcome {
        guard let recoveredIdentity = recoveryStore.recoveredIdentity,
              let request = recoveredIdentity.finishRequest else {
            return .none
        }

        if lifecycle.state == .ended,
           confirmedTerminalSummarySessionID == recoveredIdentity.sessionID,
           summary != nil,
           isTerminalPublicationPending || isTerminalArchivePending {
            // The HealthKit result and rich summary were already confirmed in
            // this process. A queued no-session recovery signal must retry
            // only durable publication/archival, never replace that summary
            // with the intentionally lossy relaunch reconstruction.
            identity = recoveredIdentity
            setupState = .ready
            if isTerminalPublicationPending {
                retryTerminalPublicationAndArchive()
            } else {
                retryDetachedSessionCleanup()
            }
            return .recovered
        }

        guard restoreDetachedFinalizationLifecycle(from: recoveredIdentity) else {
            return .failed
        }
        setupState = .ready
        publishSnapshotImmediately()
        if let injectedDetachedRecoveryPause {
            await injectedDetachedRecoveryPause()
        }

        if request.disposition == .discard {
            if recoveredIdentity.corruptResetPendingFinishChoice == true {
                // A reset-protected identity may represent a metadata-less
                // session, so a synthetic tombstone cannot match a late
                // callback. Keep the durable discard attached until the real
                // session is recovered and its builder is actually discarded.
                finishRequestError = .reconciliationFailed
                return .recovered
            }
            // Move completed no-session discards into a bounded tombstone.
            // This releases the UI while preserving an explicit discard-only
            // instruction for any genuinely late matching HealthKit builder.
            completeDetachedDiscardFinalization(
                summary: makeSummary(
                    outcome: .discarded,
                    endDate: request.requestedAt,
                    routeDistanceMeters: nil,
                    routeStatus: .unavailable
                )
            )
            return .recovered
        }

        switch request.phase {
        case .workoutSaved:
            completeDetachedFinalization(
                summary: makeDetachedSavedSummary(identity: recoveredIdentity)
            )
        case .finishAttempted:
            await reconcileDetachedSave()
        case .requested, .collectionEnded:
            finishRequestError = .reconciliationFailed
            publishSnapshotImmediately()
        }
        return .recovered
    }

    @discardableResult
    func restoreDetachedFinalizationLifecycle(
        from recoveredIdentity: WatchWorkoutRecoveryStore.Identity
    ) -> Bool {
        guard let request = recoveredIdentity.finishRequest else { return false }
        if lifecycle.state == .ending {
            guard lifecycle.finishDisposition == request.disposition else {
                return false
            }
            identity = recoveredIdentity
            return true
        }
        guard lifecycle.apply(.requestStart),
              lifecycle.apply(.sessionRunning),
              lifecycle.apply(.requestEnd(request.disposition)) else {
            return false
        }
        identity = recoveredIdentity
        return true
    }

    func reconcileDetachedSave() async {
        guard !isDetachedSaveReconciliationInProgress,
              session == nil,
              let identity = recoveryStore.recoveredIdentity ?? identity,
              let request = identity.finishRequest,
              request.disposition == .save else {
            finishRequestError = .reconciliationFailed
            return
        }
        if request.phase == .workoutSaved {
            completeDetachedFinalization(
                summary: makeDetachedSavedSummary(identity: identity)
            )
            return
        }
        guard request.phase == .finishAttempted else {
            finishRequestError = .reconciliationFailed
            publishSnapshotImmediately()
            return
        }
        isDetachedSaveReconciliationInProgress = true
        defer { isDetachedSaveReconciliationInProgress = false }
        let expectedSessionID = identity.sessionID
        let expectedStartDate = identity.startDate
        do {
            let workout = try await savedWorkout(
                externalUUID: identity.sessionID.uuidString,
                startDate: identity.startDate
            )
            guard session == nil,
                  lifecycle.state == .ending,
                  let currentIdentity = recoveryStore.recoveredIdentity,
                  currentIdentity.sessionID == expectedSessionID,
                  abs(
                      currentIdentity.startDate.timeIntervalSince(expectedStartDate)
                  ) <= 2,
                  currentIdentity.finishRequest?.disposition == .save,
                  currentIdentity.finishRequest?.phase == .finishAttempted else {
                finishRequestError = .reconciliationFailed
                return
            }
            guard let workout else {
                // Query visibility is not authoritative evidence that a prior
                // finishWorkout call failed. Keep commit-unknown recovery
                // reconciliation-only to prevent a duplicate HealthKit save.
                finishRequestError = .reconciliationFailed
                publishSnapshotImmediately()
                return
            }
            reconciledSavedWorkout = workout
            try? recoveryStore.markWorkoutSaved()
            if let durableIdentity = recoveryStore.recoveredIdentity {
                self.identity = durableIdentity
            }
            completeDetachedFinalization(
                summary: makeSummary(
                    from: workout,
                    routeStatus: request.routeStatus ?? .unknown
                )
            )
        } catch {
            finishRequestError = .reconciliationFailed
            publishSnapshotImmediately()
        }
    }

    private func completeDetachedFinalization(summary: WatchWorkoutSummary) {
        completeConfirmedSave(
            summary: summary,
            savedAt: summary.endedAt
        )
        routeRecorder.completeAfterWorkoutAlreadySaved()
    }

    private func completeDetachedDiscardFinalization(
        summary: WatchWorkoutSummary
    ) {
        completeConfirmedDiscard(
            summary: summary,
            discardedAt: summary.endedAt
        )
        routeRecorder.discardRoute()
    }

    func recoverTerminalTombstoneSessionIfPresent(
        using adapter: WatchRecoveredTerminalSessionAdapter,
        transitionDate: Date = Date()
    ) -> WorkoutRecoveryAttemptOutcome? {
        guard let tombstone = terminalTombstoneForRecoveredSession(
            metadata: adapter.metadata(),
            startDate: adapter.startDate
        ) else {
            return nil
        }
        adapter.attachRuntime()
        terminalCleanupSessionID = tombstone.sessionID
        terminalCleanupDisposition = tombstone.disposition
        setupState = .ready

        handleTerminalTombstoneSessionState(
            adapter.sessionState(),
            transitionDate: transitionDate,
            disposition: tombstone.disposition,
            adapter: WatchTerminalSessionCleanupAdapter(
                stopSession: { date in
                    adapter.stopSession(date)
                },
                completeSession: { [weak self] _ in
                    self?.completeTerminalTombstoneCleanup(
                        sessionID: tombstone.sessionID,
                        disposition: tombstone.disposition,
                        discardWorkout: adapter.discardWorkout,
                        endSession: adapter.endSession,
                        releaseSession: adapter.releaseSession
                    )
                }
            )
        )
        return .recovered
    }

    func terminalTombstoneForRecoveredSession(
        metadata: [String: Any],
        startDate: Date?
    ) -> WatchWorkoutRecoveryStore.TerminalTombstone? {
        recoveryStore.terminalTombstone(
            externalUUID: metadata[HKMetadataKeyExternalUUID] as? String,
            recoveredSessionStartDate: startDate
        )
    }

    func handleTerminalTombstoneSessionState(
        _ state: HKWorkoutSessionState,
        transitionDate: Date,
        disposition: WorkoutFinishDisposition,
        adapter: WatchTerminalSessionCleanupAdapter
    ) {
        switch state {
        case .stopped, .ended, .notStarted, .prepared:
            adapter.completeSession(disposition)
        case .running, .paused:
            adapter.stopSession(transitionDate)
        @unknown default:
            adapter.stopSession(transitionDate)
        }
    }

    private func completeTerminalTombstoneSessionCleanup(
        _ recoveredSession: HKWorkoutSession,
        builder recoveredBuilder: HKLiveWorkoutBuilder,
        sessionID: UUID,
        disposition: WorkoutFinishDisposition
    ) {
        recoveredSession.delegate = nil
        completeTerminalTombstoneCleanup(
            sessionID: sessionID,
            disposition: disposition,
            discardWorkout: {
                recoveredBuilder.discardWorkout()
            },
            endSession: {
                recoveredSession.end()
            },
            releaseSession: { [weak self] in
                guard let self, self.session === recoveredSession else { return }
                self.session = nil
                self.builder = nil
            }
        )
    }

    func completeTerminalTombstoneCleanup(
        sessionID: UUID,
        disposition: WorkoutFinishDisposition,
        discardWorkout: () -> Void,
        endSession: () -> Void,
        releaseSession: () -> Void
    ) {
        if disposition == .discard {
            discardWorkout()
        }
        endSession()
        try? recoveryStore.removeTerminalTombstone(sessionID: sessionID)
        releaseSession()
        terminalCleanupSessionID = nil
        terminalCleanupDisposition = nil
        setupState = .ready
        let hasCurrentActiveIdentity = recoveryStore.recoveredIdentity != nil
        let hasQueuedRecovery = recoverySignalQueue.consumeAfterSessionRelease()
        if hasCurrentActiveIdentity {
            _ = recoverySignalQueue.recordSignal(hasAttachedSession: false)
        }
        if hasCurrentActiveIdentity || hasQueuedRecovery {
            if !isRecoveryLoopRunning {
                isRecovering = false
                startRecoveryLoopIfNeeded()
            }
        } else {
            isRecovering = false
        }
    }

    private func attachRecoveredRouteBuilder(
        _ recoveredBuilder: HKLiveWorkoutBuilder,
        startDate: Date
    ) {
        let routeBuilder = recoveredBuilder.seriesBuilder(
            for: HKSeriesType.workoutRoute()
        ) as? HKWorkoutRouteBuilder
        routeRecorder.begin(
            routeBuilder: routeBuilder,
            startDate: startDate,
            mayContainExistingRouteData: true
        ) { [weak self] in
            self?.scheduleCoalescedSnapshot()
        }
    }

    func resumeRecoveredStoppedSaveFinalization() async {
        let runtimeAdapter: WatchRecoveredSaveRuntimeAdapter
        if let injectedRecoveredSaveRuntimeAdapter {
            runtimeAdapter = injectedRecoveredSaveRuntimeAdapter
        } else if let workoutSession = session,
                  let workoutBuilder = builder {
            runtimeAdapter = WatchRecoveredSaveRuntimeAdapter(
                session: workoutSession,
                builder: workoutBuilder,
                sessionState: { workoutSession.state }
            )
        } else {
            finishRequestError = .reconciliationFailed
            return
        }
        let workoutSession = runtimeAdapter.session
        let workoutBuilder = runtimeAdapter.builder
        guard lifecycle.state == .ending,
              finalizationTask == nil,
              Self.canRetryFinalization(
                  sessionState: runtimeAdapter.sessionState()
              ) else {
            finishRequestError = .reconciliationFailed
            return
        }
        guard var durableIdentity = recoveryStore.recoveredIdentity ?? identity else {
            finishRequestError = .reconciliationFailed
            return
        }
        let hadPendingRollback = isFinishFailureRollbackPending
        guard WatchFinishFailureRollbackCoordinator.persistBeforeRetry(
            isPending: &isFinishFailureRollbackPending,
            markFinishFailed: { [recoveryStore] in
                try recoveryStore.markFinishFailed()
            }
        ) else {
            finishRequestError = .saveFailed
            return
        }
        if hadPendingRollback {
            guard let rolledBackIdentity = recoveryStore.recoveredIdentity else {
                finishRequestError = .saveFailed
                return
            }
            durableIdentity = rolledBackIdentity
            identity = rolledBackIdentity
        }
        identity = durableIdentity
        let expectedSessionID = durableIdentity.sessionID
        let expectedStartDate = durableIdentity.startDate
        requiresRecoveredSaveReconciliation = true

        await performRecoveredSaveReconciliation(
            resolve: { [self] in
                if let injectedRecoveredSaveResolver {
                    return await injectedRecoveredSaveResolver(
                        workoutBuilder,
                        durableIdentity
                    )
                }
                return await resolveRecoveredSave(
                    builder: workoutBuilder,
                    identity: durableIdentity
                )
            },
            isContextCurrent: { [self] in
                session === workoutSession
                    && builder === workoutBuilder
                    && lifecycle.state == .ending
                    && finalizationTask == nil
                    && Self.canRetryFinalization(
                        sessionState: runtimeAdapter.sessionState()
                    )
                    && isBuilderReadyForFinalization
                    && recoveryStore.recoveredIdentity.map {
                        $0.sessionID == expectedSessionID
                            && abs(
                                $0.startDate.timeIntervalSince(expectedStartDate)
                            ) <= 2
                            && $0.finishRequest?.disposition == .save
                    } == true
            },
            apply: { [self] resolution in
                applyRecoveredSaveResolution(
                    resolution,
                    durableIdentity: durableIdentity,
                    workoutBuilder: workoutBuilder,
                    workoutSession: workoutSession
                )
            }
        )
    }

    /// Runs the saved-workout query while holding the same gate consulted by
    /// session callbacks, then applies the selected mode synchronously after
    /// post-await context validation and gate release.
    func performRecoveredSaveReconciliation(
        resolve: () async -> RecoveredSaveResolution,
        isContextCurrent: () -> Bool,
        apply: (RecoveredSaveResolution) -> Void
    ) async {
        guard recoveredSaveReconciliationGate.begin() else { return }
        var reconciliationGateHeld = true
        defer {
            if reconciliationGateHeld {
                recoveredSaveReconciliationGate.end()
            }
        }

        let resolution = await resolve()
        guard isContextCurrent() else {
            finishRequestError = .reconciliationFailed
            return
        }
        recoveredSaveReconciliationGate.end()
        reconciliationGateHeld = false
        apply(resolution)
    }

    private func applyRecoveredSaveResolution(
        _ resolution: RecoveredSaveResolution,
        durableIdentity originalIdentity: WatchWorkoutRecoveryStore.Identity,
        workoutBuilder: HKLiveWorkoutBuilder,
        workoutSession: HKWorkoutSession
    ) {
        var durableIdentity = originalIdentity
        switch resolution.action {
        case .retryReconciliation:
            finishRequestError = .reconciliationFailed
            return
        case .finalize(let mode):
            if !persistQueryConfirmedSaveBeforeTerminalization(
                resolution.workout != nil
            ) {
                finishRequestError = .reconciliationFailed
                return
            }
            if resolution.workout != nil {
                guard let confirmedIdentity = recoveryStore.recoveredIdentity else {
                    finishRequestError = .reconciliationFailed
                    return
                }
                durableIdentity = confirmedIdentity
                identity = confirmedIdentity
            }
            finishRequestError = nil
            reconciledSavedWorkout = resolution.workout
            if mode == .full,
               preparedRouteForFinalization == nil {
                attachRecoveredRouteBuilder(
                    workoutBuilder,
                    startDate: durableIdentity.startDate
                )
                routeRecorder.stopLocationUpdates()
            }
            beginRecoveredSaveFinalization(
                mode: mode,
                at: workoutSession.endDate
                    ?? durableIdentity.finishRequest?.requestedAt
                    ?? Date()
            )
        }
    }

    func beginRecoveredSaveFinalization(
        mode: WorkoutSaveFinalizationMode,
        at endDate: Date
    ) {
        requiresRecoveredSaveReconciliation = false
        recoveredSaveMode = mode
        beginFinalizationAfterStop(at: endDate)
    }

    private func resolveRecoveredSave(
        builder: HKLiveWorkoutBuilder,
        identity: WatchWorkoutRecoveryStore.Identity
    ) async -> RecoveredSaveResolution {
        if let reconciledSavedWorkout {
            return RecoveredSaveResolution(
                action: .finalize(.alreadySaved),
                workout: reconciledSavedWorkout
            )
        }
        let phase = identity.finishRequest?.phase ?? .requested
        if phase == .workoutSaved {
            return RecoveredSaveResolution(
                action: .finalize(.alreadySaved),
                workout: nil
            )
        }

        let externalUUID = injectedRecoveredSaveRuntimeAdapter?
            .externalUUID?()
            ?? builder.metadata[HKMetadataKeyExternalUUID] as? String
        let builderCollectionEnded = injectedRecoveredSaveRuntimeAdapter?
            .builderCollectionEnded?()
            ?? (builder.endDate != nil)
        guard let externalUUID,
              externalUUID == identity.sessionID.uuidString else {
            return RecoveredSaveResolution(
                action: WorkoutRecoveredSavePolicy.action(
                    phase: phase,
                    builderCollectionEnded: builderCollectionEnded,
                    matchingWorkout: .unavailable
                ),
                workout: nil
            )
        }

        do {
            let workout = try await savedWorkout(
                externalUUID: externalUUID,
                startDate: identity.startDate
            )
            return RecoveredSaveResolution(
                action: WorkoutRecoveredSavePolicy.action(
                    phase: phase,
                    builderCollectionEnded: builderCollectionEnded,
                    matchingWorkout: workout == nil ? .notFound : .found
                ),
                workout: workout
            )
        } catch {
            return RecoveredSaveResolution(
                action: WorkoutRecoveredSavePolicy.action(
                    phase: phase,
                    builderCollectionEnded: builderCollectionEnded,
                    matchingWorkout: .queryFailed
                ),
                workout: nil
            )
        }
    }

    private func beginFinalizationAfterStop(at endDate: Date) {
        guard recoveredSaveReconciliationGate.allowsFinalization,
              !requiresRecoveredSaveReconciliation,
              !isFinishFailureRollbackPending else {
            return
        }
        if let injectedFinalizationClaimObserver {
            guard finalizationTask == nil,
                  lifecycle.claimFinalization() != nil else {
                return
            }
            injectedFinalizationClaimObserver(recoveredSaveMode)
            return
        }
        guard isBuilderReadyForFinalization
                || injectedRecoveredDiscardFinalizationAdapter != nil,
              finalizationTask == nil,
              let disposition = lifecycle.claimFinalization() else {
            return
        }
        let resolvedEndDate = WorkoutFinalizationEndDatePolicy.resolve(
            authoritativeEndDate: authoritativeFinalizationEndDate,
            callbackDate: endDate
        )
        authoritativeFinalizationEndDate = nil
        periodicSnapshotTask?.cancel()
        periodicSnapshotTask = nil
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            await finalize(disposition: disposition, endDate: resolvedEndDate)
            finalizationTask = nil
        }
    }

    func handleSessionReadyForFinalization(at endDate: Date) {
        switch WorkoutSessionFailurePolicy.action(for: lifecycle.state) {
        case .failStart:
            handleStartFailure(nil)
        case .savePartialWorkout:
            requestEnd(.save, requestedAt: endDate)
        case .finishRequestedDisposition:
            beginFinalizationAfterStop(at: endDate)
        case .ignore:
            break
        }
    }

    /// A reset-authorized cleanup can be adopted before HealthKit exposes its
    /// stable metadata. Re-read it at the final non-destructive boundary so a
    /// queued recovery callback can match the terminal tombstone by the real
    /// builder UUID. A failed bind keeps the stopped builder and session for
    /// an explicit retry.
    private func bindRecoveredDiscardIdentityBeforeFinalization(
        metadata: [String: Any]
    ) -> Bool {
        guard let currentIdentity = recoveryStore.recoveredIdentity,
              currentIdentity.finishRequest?.disposition == .discard,
              currentIdentity.corruptResetPendingFinishChoice == true,
              currentIdentity.corruptResetSyntheticCleanupIdentity == true,
              currentIdentity.healthKitSessionID == nil,
              let stableSessionID = Self.workoutIdentitySessionID(from: metadata) else {
            return true
        }

        do {
            let reboundIdentity = try recoveryStore.useRecoveredIdentity(
                startDate: currentIdentity.startDate,
                stableSessionID: stableSessionID
            )
            guard reboundIdentity.sessionID == currentIdentity.sessionID,
                  reboundIdentity.healthKitSessionID == stableSessionID
                    || reboundIdentity.sessionID == stableSessionID else {
                lifecycle.releaseFinalizationClaimForRetry()
                finishRequestError = .reconciliationFailed
                lastErrorCode = .sessionFailed
                return false
            }
            identity = reboundIdentity
            return true
        } catch {
            lifecycle.releaseFinalizationClaimForRetry()
            finishRequestError = .reconciliationFailed
            lastErrorCode = .sessionFailed
            return false
        }
    }

    private func finalize(
        disposition: WorkoutFinishDisposition,
        endDate: Date
    ) async {
        if disposition == .discard {
            let metadata = injectedRecoveredDiscardFinalizationAdapter?
                .metadata()
                ?? builder?.metadata
                ?? [:]
            guard bindRecoveredDiscardIdentityBeforeFinalization(
                metadata: metadata
            ) else {
                return
            }
        }
        if disposition == .discard,
           let adapter = injectedRecoveredDiscardFinalizationAdapter {
            do {
                let outcome = try await WorkoutFinalizationOrchestrator.run(
                    disposition: .discard,
                    discardWorkout: {
                        adapter.discardWorkout()
                    },
                    discardRoute: {
                        adapter.discardRoute()
                    },
                    prepareRoute: {
                        WorkoutPreparedRoute(
                            routeStatus: .unavailable,
                            distanceMeters: nil
                        )
                    },
                    endCollection: {},
                    finishWorkout: {},
                    endSession: {
                        adapter.endSession()
                    }
                )
                guard outcome == .discarded else { return }
                completeConfirmedDiscard(
                    summary: makeSummary(
                        outcome: .discarded,
                        endDate: endDate,
                        routeDistanceMeters: nil,
                        routeStatus: .unavailable
                    ),
                    discardedAt: endDate
                )
            } catch {
                lifecycle.releaseFinalizationClaimForRetry()
                finishRequestError = .saveFailed
            }
            return
        }
        guard let builder, let session else {
            handleStartFailure(nil)
            return
        }

        do {
            let saveMode = recoveredSaveMode ?? .full
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: disposition,
                saveMode: saveMode,
                discardWorkout: {
                    builder.discardWorkout()
                },
                discardRoute: { [routeRecorder] in
                    routeRecorder.discardRoute()
                },
                completeAlreadySavedRoute: { [routeRecorder] in
                    routeRecorder.completeAfterWorkoutAlreadySaved()
                },
                prepareRoute: { [routeRecorder] in
                    if let preparedRouteForFinalization = self.preparedRouteForFinalization {
                        return preparedRouteForFinalization
                    }
                    let route = await routeRecorder.prepareForWorkoutFinalization()
                    self.preparedRouteForFinalization = route
                    return route
                },
                recoveredRouteStatus: identity?.finishRequest?.routeStatus ?? .unknown,
                markPreparedRoute: { [recoveryStore] status in
                    try recoveryStore.markPreparedRoute(status)
                },
                endCollection: { [weak self] in
                    guard let self else { throw WorkoutFinalizationError.managerReleased }
                    try await endCollection(builder, at: endDate)
                    updateAllMetrics(from: builder, capturedAt: endDate)
                },
                markCollectionEnded: { [recoveryStore] in
                    try recoveryStore.markCollectionEnded()
                },
                markFinishAttempted: { [recoveryStore] in
                    try recoveryStore.markFinishAttempted()
                },
                finishWorkout: { [weak self] in
                    guard let self else { throw WorkoutFinalizationError.managerReleased }
                    try await finishWorkout(builder)
                },
                markFinishFailed: { [recoveryStore] in
                    try recoveryStore.markFinishFailed()
                },
                markWorkoutSaved: { [recoveryStore] in
                    try recoveryStore.markWorkoutSaved()
                },
                workoutSavedPersistenceFailed: { [weak self] in
                    self?.isTerminalArchivePending = true
                },
                endSession: {
                    session.end()
                }
            )
            switch outcome {
            case .discarded:
                let summary = makeSummary(
                    outcome: .discarded,
                    endDate: endDate,
                    routeDistanceMeters: nil,
                    routeStatus: .unavailable
                )
                completeConfirmedDiscard(
                    summary: summary,
                    discardedAt: endDate
                )
            case .saved(let route):
                let summary: WatchWorkoutSummary
                if let reconciledSavedWorkout {
                    summary = makeSummary(
                        from: reconciledSavedWorkout,
                        routeStatus: route.routeStatus
                    )
                } else {
                    let route = preparedRouteForFinalization ?? route
                    terminalRouteDistance = WorkoutTerminalRouteDistancePolicy.candidate(
                        distanceMeters: route.distanceMeters,
                        capturedAt: endDate
                    )
                    summary = makeSummary(
                        outcome: .saved,
                        endDate: endDate,
                        routeDistanceMeters: route.distanceMeters,
                        routeStatus: route.routeStatus
                    )
                }
                completeConfirmedSave(
                    summary: summary,
                    savedAt: endDate
                )
            }
        } catch {
            if case WorkoutFinalizationPersistenceError
                .finishFailureRollbackPending = error {
                isFinishFailureRollbackPending = true
            }
            lastErrorCode = .sessionFailed
            lifecycle.releaseFinalizationClaimForRetry()
            finishRequestError = .saveFailed
            publishSnapshotImmediately()
        }
    }

    func completeConfirmedSave(
        summary: WatchWorkoutSummary,
        savedAt: Date
    ) {
        identity = identity ?? recoveryStore.recoveredIdentity
        let didPublish = WatchTerminalPublicationCoordinator.perform(
            publishTerminal: { [self] in
                completeFinalization(summary: summary)
            },
            archiveIdentity: { [self] in
                archiveConfirmedSave(at: savedAt)
            }
        )
        finishTerminalRuntimeAfterPublication(didPublish)
    }

    func completeConfirmedDiscard(
        summary: WatchWorkoutSummary,
        discardedAt: Date
    ) {
        identity = identity ?? recoveryStore.recoveredIdentity
        let didPublish = WatchTerminalPublicationCoordinator.perform(
            publishTerminal: { [self] in
                completeFinalization(summary: summary)
            },
            archiveIdentity: { [self] in
                archiveConfirmedDiscard(at: discardedAt)
            }
        )
        finishTerminalRuntimeAfterPublication(didPublish)
    }

    @discardableResult
    func persistQueryConfirmedSaveBeforeTerminalization(
        _ isConfirmed: Bool
    ) -> Bool {
        guard isConfirmed else { return true }
        do {
            // A stable-ID HealthKit match is authoritative even when the
            // local phase predates finishAttempted.
            try recoveryStore.markWorkoutSaved()
            identity = recoveryStore.recoveredIdentity
            return identity != nil
        } catch {
            return false
        }
    }

    private func archiveConfirmedSave(at savedAt: Date) {
        do {
            _ = try recoveryStore.archiveConfirmedSavedIdentity(at: savedAt)
            isTerminalArchivePending = false
            isTerminalPublicationPending = false
            confirmedTerminalSummarySessionID = nil
            confirmedTerminalSnapshot = nil
            identity = nil
            reconciledSavedWorkout = nil
        } catch {
            // HealthKit's successful finish callback is authoritative. Keep
            // the finish-attempt identity until its terminal tombstone can be
            // persisted; do not make another save call.
            isTerminalArchivePending = true
            isTerminalPublicationPending = false
            identity = recoveryStore.recoveredIdentity
        }
    }

    private func archiveConfirmedDiscard(at discardedAt: Date) {
        do {
            _ = try recoveryStore.archiveConfirmedDiscardedIdentity(
                at: discardedAt
            )
            isTerminalArchivePending = false
            isTerminalPublicationPending = false
            confirmedTerminalSummarySessionID = nil
            confirmedTerminalSnapshot = nil
            identity = nil
        } catch {
            isTerminalArchivePending = true
            isTerminalPublicationPending = false
            identity = recoveryStore.recoveredIdentity
        }
    }

    @discardableResult
    private func completeFinalization(
        summary: WatchWorkoutSummary
    ) -> Bool {
        finishRequestError = nil
        lastErrorCode = nil
        confirmedTerminalSummarySessionID = (
            recoveryStore.recoveredIdentity ?? identity
        )?.sessionID
        self.summary = summary
        _ = lifecycle.apply(.sessionEnded)
        let terminalSnapshot = makeSnapshot(capturedAt: Date())
        confirmedTerminalSnapshot = terminalSnapshot
        guard publishSnapshotImmediately(snapshotOverride: terminalSnapshot) else {
            // Keep the durable identity until a transportable terminal
            // envelope exists. HealthKit finalization is already complete,
            // so release only its runtime objects and expose cleanup retry.
            isTerminalPublicationPending = true
            finishRequestError = .reconciliationFailed
            releaseHealthKitObjectsAfterTerminalPublicationFailure()
            return false
        }
        isTerminalPublicationPending = false
        return true
    }

    private func finishTerminalRuntimeAfterPublication(_ didPublish: Bool) {
        guard didPublish else { return }
        if isTerminalArchivePending {
            releaseHealthKitObjectsAfterTerminalPublicationFailure()
        } else {
            clearActiveObjects()
        }
    }

    private func retryTerminalPublicationAndArchive() {
        guard let terminalSummary = summary,
              let terminalSnapshot = confirmedTerminalSnapshot,
              let durableIdentity = recoveryStore.recoveredIdentity ?? identity,
              let request = durableIdentity.finishRequest else {
            finishRequestError = .reconciliationFailed
            return
        }
        identity = durableIdentity
        finishRequestError = nil
        lastErrorCode = nil
        guard publishSnapshotImmediately(snapshotOverride: terminalSnapshot) else {
            isTerminalPublicationPending = true
            finishRequestError = .reconciliationFailed
            return
        }

        isTerminalPublicationPending = false
        switch request.disposition {
        case .save:
            archiveConfirmedSave(at: terminalSummary.endedAt)
        case .discard:
            archiveConfirmedDiscard(at: terminalSummary.endedAt)
        }
        finishRequestError = isTerminalArchivePending
            ? .reconciliationFailed
            : nil
        if isTerminalArchivePending {
            releaseHealthKitObjectsAfterTerminalPublicationFailure()
        } else {
            clearActiveObjects()
        }
    }

    private func releaseHealthKitObjectsAfterTerminalPublicationFailure() {
        session = nil
        builder = nil
        authoritativeFinalizationEndDate = nil
        isBuilderReadyForFinalization = false
        isIdentityMetadataRetryPending = false
        requiresRecoveredSaveReconciliation = false
        recoveredSaveMode = nil
        preparedRouteForFinalization = nil
        terminalCleanupSessionID = nil
        terminalCleanupDisposition = nil
        periodicSnapshotTask?.cancel()
        periodicSnapshotTask = nil
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        handleAttachedSessionRelease()
    }

    private func clearActiveObjects() {
        session = nil
        builder = nil
        identity = nil
        authoritativeFinalizationEndDate = nil
        isBuilderReadyForFinalization = false
        isIdentityMetadataRetryPending = false
        requiresRecoveredSaveReconciliation = false
        isTerminalPublicationPending = false
        recoveredSaveMode = nil
        reconciledSavedWorkout = nil
        preparedRouteForFinalization = nil
        terminalCleanupSessionID = nil
        terminalCleanupDisposition = nil
        confirmedTerminalSummarySessionID = nil
        confirmedTerminalSnapshot = nil
        terminalRouteDistance = nil
        isFinishFailureRollbackPending = false
        isDetachedSaveReconciliationInProgress = false
        periodicSnapshotTask?.cancel()
        periodicSnapshotTask = nil
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        handleAttachedSessionRelease()
    }

    private func updateMetrics(
        from builder: HKLiveWorkoutBuilder,
        collectedTypes: Set<HKSampleType>,
        capturedAt: Date
    ) {
        for sampleType in collectedTypes {
            guard let quantityType = sampleType as? HKQuantityType,
                  let statistics = builder.statistics(for: quantityType) else {
                continue
            }
            updateMetric(
                identifier: quantityType.identifier,
                statistics: statistics,
                capturedAt: capturedAt
            )
        }
        scheduleCoalescedSnapshot()
    }

    private func updateAllMetrics(
        from builder: HKLiveWorkoutBuilder,
        capturedAt: Date
    ) {
        for (quantityType, statistics) in builder.allStatistics {
            updateMetric(
                identifier: quantityType.identifier,
                statistics: statistics,
                capturedAt: capturedAt
            )
        }
    }

    private func updateMetric(
        identifier: String,
        statistics: HKStatistics,
        capturedAt: Date
    ) {
        switch identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            let unit = HKUnit.count().unitDivided(by: .minute())
            if let quantity = statistics.mostRecentQuantity() {
                let date = statistics.mostRecentQuantityDateInterval()?.end ?? capturedAt
                currentHeartRate = positiveMetric(
                    quantity.doubleValue(for: unit),
                    unit: .beatsPerMinute,
                    capturedAt: min(date, capturedAt)
                )
            }
            if let quantity = statistics.averageQuantity() {
                averageHeartRate = positiveMetric(
                    quantity.doubleValue(for: unit),
                    unit: .beatsPerMinute,
                    capturedAt: capturedAt
                )
            }
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            if let quantity = statistics.sumQuantity() {
                activeEnergy = nonnegativeMetric(
                    quantity.doubleValue(for: .kilocalorie()),
                    unit: .kilocalories,
                    capturedAt: capturedAt
                )
            }
        case HKQuantityTypeIdentifier.distanceCycling.rawValue:
            if let quantity = statistics.sumQuantity() {
                let value = quantity.doubleValue(for: .meter())
                healthKitDistance = WorkoutMetricCandidate(
                    value: value,
                    capturedAt: capturedAt,
                    source: .healthKit
                )
            }
        case HKQuantityTypeIdentifier.cyclingSpeed.rawValue:
            if let quantity = statistics.mostRecentQuantity() {
                let unit = HKUnit.meter().unitDivided(by: .second())
                let date = statistics.mostRecentQuantityDateInterval()?.end ?? capturedAt
                pairedSensorSpeed = WorkoutMetricCandidate(
                    value: quantity.doubleValue(for: unit),
                    capturedAt: min(date, capturedAt),
                    source: .pairedCyclingSensor
                )
            }
        case HKQuantityTypeIdentifier.cyclingPower.rawValue:
            if let quantity = statistics.mostRecentQuantity() {
                let date = statistics.mostRecentQuantityDateInterval()?.end ?? capturedAt
                cyclingPower = nonnegativeMetric(
                    quantity.doubleValue(for: .watt()),
                    unit: .watts,
                    capturedAt: min(date, capturedAt)
                )
            }
        case HKQuantityTypeIdentifier.cyclingCadence.rawValue:
            if let quantity = statistics.mostRecentQuantity() {
                let unit = HKUnit.count().unitDivided(by: .minute())
                let date = statistics.mostRecentQuantityDateInterval()?.end ?? capturedAt
                cyclingCadence = nonnegativeMetric(
                    quantity.doubleValue(for: unit),
                    unit: .revolutionsPerMinute,
                    capturedAt: min(date, capturedAt)
                )
            }
        default:
            break
        }
    }

    private func startPeriodicSnapshots() {
        guard periodicSnapshotTask == nil else { return }
        periodicSnapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                scheduleCoalescedSnapshot()
            }
        }
    }

    private func scheduleCoalescedSnapshot() {
        guard lifecycle.state.isActive, coalescedSnapshotTask == nil else { return }
        let elapsed = Date().timeIntervalSince(lastSnapshotPublishedAt)
        if elapsed >= 1 {
            publishSnapshotImmediately()
            return
        }
        let delay = max(0, 1 - elapsed)
        coalescedSnapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            coalescedSnapshotTask = nil
            publishSnapshotImmediately()
        }
    }

    @discardableResult
    private func publishSnapshotImmediately(
        snapshotOverride: WorkoutSnapshotV1? = nil
    ) -> Bool {
        guard let identity else { return false }
        coalescedSnapshotTask?.cancel()
        coalescedSnapshotTask = nil
        let capturedAt = Date()
        let snapshot = snapshotOverride ?? makeSnapshot(capturedAt: capturedAt)
        self.snapshot = snapshot
        lastSnapshotPublishedAt = capturedAt
        guard let sequence = recoveryStore.nextSequence() else {
            lastErrorCode = .sessionFailed
            return false
        }
        let envelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: identity.sessionID,
            sessionToken: identity.sessionToken,
            transportGenerationID:
                identity.transportGenerationID ?? identity.sessionID,
            sequence: sequence,
            capturedAt: capturedAt,
            snapshot: snapshot
        )
        guard (try? WorkoutContractCodec.validate(envelope)) != nil else {
            return false
        }
        latestEnvelope = envelope
        return true
    }

    private func publishFailureSnapshot() {
        let capturedAt = Date()
        let failedSnapshot = WorkoutSnapshotV1(
            state: .failed,
            startDate: identity?.startDate ?? snapshot.startDate,
            availability: [],
            errorCode: lastErrorCode ?? .sessionFailed
        )
        snapshot = failedSnapshot
        lastSnapshotPublishedAt = capturedAt

        guard let identity,
              let sequence = recoveryStore.nextSequence() else {
            return
        }
        let envelope = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: identity.sessionID,
            sessionToken: identity.sessionToken,
            transportGenerationID:
                identity.transportGenerationID ?? identity.sessionID,
            sequence: sequence,
            capturedAt: capturedAt,
            snapshot: failedSnapshot
        )
        guard (try? WorkoutContractCodec.validate(envelope)) != nil else { return }
        latestEnvelope = envelope
    }

    private func makeSnapshot(capturedAt: Date) -> WorkoutSnapshotV1 {
        let elapsedTime = WorkoutElapsedTimePolicy.metric(
            builderElapsedTime: injectedBuilderElapsedTime?(builder)
                ?? builder?.elapsedTime
                ?? .nan,
            startDate: identity?.startDate,
            capturedAt: capturedAt
        )

        let currentHeartRate = WorkoutMetricFreshness.metric(
            self.currentHeartRate,
            now: capturedAt,
            maximumAge: WorkoutMetricFreshness.heartRateMaximumAge
        )
        let cyclingPower = WorkoutMetricFreshness.metric(
            self.cyclingPower,
            now: capturedAt,
            maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
        )
        let cyclingCadence = WorkoutMetricFreshness.metric(
            self.cyclingCadence,
            now: capturedAt,
            maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
        )
        let freshLocation = routeRecorder.latestLocation.flatMap { location in
            WorkoutMetricFreshness.isFresh(
                capturedAt: location.timestamp,
                now: capturedAt,
                maximumAge: WorkoutMetricFreshness.watchLocationMaximumAge
            ) ? location : nil
        }
        let location = makeLocation(
            from: freshLocation,
            capturedAt: capturedAt
        )
        let liveRouteDistance: WorkoutMetricCandidate? = routeRecorder.routeDistanceMeters.flatMap { value in
            guard let routeDistanceCapturedAt = routeRecorder.routeDistanceCapturedAt else {
                return nil
            }
            return WorkoutMetricCandidate(
                value: value,
                capturedAt: min(routeDistanceCapturedAt, capturedAt),
                source: .watchRoute
            )
        }
        let routeDistance = terminalRouteDistance ?? liveRouteDistance
        let distanceCandidate = WorkoutMetricPrecedence.cyclingDistance(
            healthKit: healthKitDistance,
            watchRoute: routeDistance
        )
        let distance = distanceCandidate.map {
            WorkoutMetricV1(
                value: $0.value,
                unit: .meters,
                capturedAt: min($0.capturedAt, capturedAt),
                source: $0.source
            )
        }

        let locationSpeed = freshLocation.flatMap { location -> WorkoutMetricCandidate? in
            guard location.speed.isFinite, location.speed >= 0 else { return nil }
            return WorkoutMetricCandidate(
                value: location.speed,
                capturedAt: min(location.timestamp, capturedAt),
                source: .watchLocation
            )
        }
        let speedCandidate = WorkoutMetricPrecedence.currentSpeed(
            pairedSensor: WorkoutMetricFreshness.candidate(
                pairedSensorSpeed,
                now: capturedAt,
                maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
            ),
            watchLocation: locationSpeed
        )
        let speed = speedCandidate.map {
            WorkoutMetricV1(
                value: $0.value,
                unit: .metersPerSecond,
                capturedAt: min($0.capturedAt, capturedAt),
                source: $0.source
            )
        }

        var availability: WorkoutAvailabilityMaskV1 = []
        if elapsedTime != nil { availability.insert(.elapsedTime) }
        if currentHeartRate != nil { availability.insert(.currentHeartRate) }
        if averageHeartRate != nil { availability.insert(.averageHeartRate) }
        if activeEnergy != nil { availability.insert(.activeEnergy) }
        if distance != nil { availability.insert(.cyclingDistance) }
        if speed != nil { availability.insert(.currentSpeed) }
        if cyclingPower != nil { availability.insert(.cyclingPower) }
        if cyclingCadence != nil { availability.insert(.cyclingCadence) }
        if location != nil { availability.insert(.location) }
        if location?.altitude != nil { availability.insert(.altitude) }

        return WorkoutSnapshotV1(
            state: lifecycle.state,
            startDate: identity?.startDate,
            elapsedTime: elapsedTime,
            currentHeartRate: currentHeartRate,
            averageHeartRate: averageHeartRate,
            activeEnergy: activeEnergy,
            cyclingDistance: distance,
            currentSpeed: speed,
            cyclingPower: cyclingPower,
            cyclingCadence: cyclingCadence,
            currentHeartRateZone: nil,
            heartRateZoneCount: nil,
            heartRateZoneDurations: nil,
            location: location,
            availability: availability,
            errorCode: lastErrorCode
        )
    }

    private func makeLocation(
        from location: CLLocation?,
        capturedAt: Date
    ) -> WorkoutLocationV1? {
        guard let location else { return nil }
        let hasAltitude = location.verticalAccuracy.isFinite && location.verticalAccuracy >= 0
        let course = location.course.isFinite && (0..<360).contains(location.course)
            ? location.course
            : nil
        let speed = location.speed.isFinite && location.speed >= 0 ? location.speed : nil
        return WorkoutLocationV1(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            capturedAt: min(location.timestamp, capturedAt),
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: hasAltitude ? location.altitude : nil,
            verticalAccuracy: hasAltitude ? location.verticalAccuracy : nil,
            course: course,
            speed: speed
        )
    }

    private func makeSummary(
        outcome: WatchWorkoutSummary.Outcome,
        endDate: Date,
        routeDistanceMeters: Double?,
        routeStatus: WorkoutRouteSaveStatus
    ) -> WatchWorkoutSummary {
        let routeDistance = routeDistanceMeters.map { value in
            WorkoutMetricCandidate(
                value: value,
                capturedAt: endDate,
                source: .watchRoute
            )
        }
        return WatchWorkoutSummary(
            outcome: outcome,
            endedAt: endDate,
            duration: max(0, builder?.elapsedTime ?? 0),
            distanceMeters: WorkoutMetricPrecedence.cyclingDistance(
                healthKit: healthKitDistance,
                watchRoute: routeDistance
            )?.value,
            activeEnergyKilocalories: activeEnergy?.value,
            averageHeartRate: averageHeartRate?.value,
            routeStatus: routeStatus
        )
    }

    private func makeSummary(
        from workout: HKWorkout,
        routeStatus: WorkoutRouteSaveStatus
    ) -> WatchWorkoutSummary {
        let distance = HKObjectType.quantityType(forIdentifier: .distanceCycling)
            .flatMap { workout.statistics(for: $0)?.sumQuantity() }
            .map { $0.doubleValue(for: .meter()) }
            .flatMap { value in value.isFinite && value >= 0 ? value : nil }
        let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
            .flatMap { workout.statistics(for: $0)?.sumQuantity() }
            .map { $0.doubleValue(for: .kilocalorie()) }
            .flatMap { value in value.isFinite && value >= 0 ? value : nil }
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        let averageHeartRate = HKObjectType.quantityType(forIdentifier: .heartRate)
            .flatMap { workout.statistics(for: $0)?.averageQuantity() }
            .map { $0.doubleValue(for: heartRateUnit) }
            .flatMap { value in value.isFinite && value > 0 ? value : nil }
        let duration = workout.duration
        return WatchWorkoutSummary(
            outcome: .saved,
            endedAt: workout.endDate,
            duration: duration.isFinite ? max(0, duration) : 0,
            distanceMeters: distance,
            activeEnergyKilocalories: energy,
            averageHeartRate: averageHeartRate,
            routeStatus: routeStatus
        )
    }

    private func makeDetachedSavedSummary(
        identity: WatchWorkoutRecoveryStore.Identity
    ) -> WatchWorkoutSummary {
        let request = identity.finishRequest
        let endDate = request?.requestedAt ?? identity.startDate
        return WatchWorkoutSummary(
            outcome: .saved,
            endedAt: endDate,
            duration: nil,
            distanceMeters: nil,
            activeEnergyKilocalories: nil,
            averageHeartRate: nil,
            routeStatus: request?.routeStatus ?? .unknown
        )
    }

    private func clearMetrics() {
        currentHeartRate = nil
        averageHeartRate = nil
        activeEnergy = nil
        healthKitDistance = nil
        pairedSensorSpeed = nil
        cyclingPower = nil
        cyclingCadence = nil
        terminalRouteDistance = nil
        lastErrorCode = nil
    }

    private func positiveMetric(
        _ value: Double,
        unit: WorkoutMetricUnitV1,
        capturedAt: Date
    ) -> WorkoutMetricV1? {
        guard value.isFinite, value > 0 else { return nil }
        return WorkoutMetricV1(
            value: value,
            unit: unit,
            capturedAt: capturedAt,
            source: .healthKit
        )
    }

    private func nonnegativeMetric(
        _ value: Double,
        unit: WorkoutMetricUnitV1,
        capturedAt: Date
    ) -> WorkoutMetricV1? {
        guard value.isFinite, value >= 0 else { return nil }
        return WorkoutMetricV1(
            value: value,
            unit: unit,
            capturedAt: capturedAt,
            source: .healthKit
        )
    }

    private func authorizationRequestStatus() async throws -> HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<HKAuthorizationRequestStatus, Error>) in
            healthStore.getRequestStatusForAuthorization(
                toShare: Self.typesToShare,
                read: Self.typesToRead
            ) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func recoverActiveWorkoutSession() async -> (
        session: HKWorkoutSession?,
        error: Error?
    ) {
        if let injectedRecoveryOperation {
            return await injectedRecoveryOperation()
        }
        return await withCheckedContinuation { continuation in
            healthStore.recoverActiveWorkoutSession { session, error in
                continuation.resume(returning: (session, error))
            }
        }
    }

    private func savedWorkout(
        externalUUID: String,
        startDate: Date
    ) async throws -> HKWorkout? {
        if let injectedSavedWorkoutLookup {
            return try await injectedSavedWorkoutLookup(
                externalUUID,
                startDate
            )
        }
        let metadataPredicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            operatorType: .equalTo,
            value: externalUUID
        )
        let activityPredicate = HKQuery.predicateForWorkouts(
            with: .cycling
        )
        let startPredicate = HKQuery.predicateForSamples(
            withStart: startDate.addingTimeInterval(-2),
            end: startDate.addingTimeInterval(2),
            options: .strictStartDate
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            metadataPredicate,
            activityPredicate,
            startPredicate,
        ])

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<HKWorkout?, Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(
                    returning: samples?.first as? HKWorkout
                )
            }
            healthStore.execute(query)
        }
    }

    private func endCollection(
        _ builder: HKLiveWorkoutBuilder,
        at endDate: Date
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: endDate) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: WorkoutFinalizationError.endCollectionFailed)
                }
            }
        }
    }

    private func finishWorkout(
        _ builder: HKLiveWorkoutBuilder
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            builder.finishWorkout { workout, error in
                switch WorkoutFinishCallbackPolicy.outcome(
                    workoutReturned: workout != nil,
                    errorReturned: error != nil
                ) {
                case .saved:
                    continuation.resume(returning: ())
                case .failed:
                    guard let error else {
                        continuation.resume(
                            throwing: WorkoutFinalizationError.finishWorkoutFailed
                        )
                        return
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static var typesToShare: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    }

    private static var typesToRead: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        for identifier in quantityIdentifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    private static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .activeEnergyBurned,
        .distanceCycling,
        .cyclingSpeed,
        .cyclingPower,
        .cyclingCadence,
    ]

    private static func safeErrorCode(for error: Error?) -> WorkoutSafeErrorCodeV1 {
        guard let error = error as? HKError else { return .sessionFailed }
        switch error.code {
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined,
             .errorRequiredAuthorizationDenied:
            return .authorizationDenied
        case .errorAnotherWorkoutSessionStarted:
            return .anotherWorkoutActive
        default:
            return .sessionFailed
        }
    }

    private static func isAuthorizationError(_ error: Error) -> Bool {
        guard let error = error as? HKError else { return false }
        return [
            .errorAuthorizationDenied,
            .errorAuthorizationNotDetermined,
            .errorRequiredAuthorizationDenied,
        ].contains(error.code)
    }

    static func resolveSetupState(
        shareStatuses: [HKAuthorizationStatus],
        requestStatus: HKAuthorizationRequestStatus?
    ) -> WatchWorkoutSetupState? {
        if shareStatuses.contains(.sharingDenied) {
            return .denied
        }
        if let requestStatus,
           requestStatus != .unnecessary {
            return .needsAuthorization
        }
        if !shareStatuses.isEmpty,
           shareStatuses.allSatisfy({ $0 == .sharingAuthorized }) {
            return .ready
        }
        guard let requestStatus else { return nil }
        return requestStatus == .unnecessary ? .ready : .needsAuthorization
    }

    static func workoutIdentityMetadata(sessionID: UUID) -> [String: Any] {
        let identifier = sessionID.uuidString
        return [
            HKMetadataKeyExternalUUID: identifier,
            HKMetadataKeySyncIdentifier: "LetItRide.BikeComputer.workout.\(identifier)",
            HKMetadataKeySyncVersion: 1,
        ]
    }

    static func hasWorkoutIdentityMetadata(
        _ metadata: [String: Any],
        sessionID: UUID
    ) -> Bool {
        let identifier = sessionID.uuidString
        let syncVersion = (metadata[HKMetadataKeySyncVersion] as? NSNumber)?.intValue
        return metadata[HKMetadataKeyExternalUUID] as? String == identifier
            && metadata[HKMetadataKeySyncIdentifier] as? String
                == "LetItRide.BikeComputer.workout.\(identifier)"
            && syncVersion == 1
    }

    static func workoutIdentitySessionID(
        from metadata: [String: Any]
    ) -> UUID? {
        guard let externalIdentifier = metadata[HKMetadataKeyExternalUUID] as? String,
              let sessionID = UUID(uuidString: externalIdentifier),
              hasWorkoutIdentityMetadata(metadata, sessionID: sessionID) else {
            return nil
        }
        return sessionID
    }

    static func containsWorkoutIdentityMetadata(
        _ metadata: [String: Any]
    ) -> Bool {
        metadata.keys.contains(HKMetadataKeyExternalUUID)
            || metadata.keys.contains(HKMetadataKeySyncIdentifier)
            || metadata.keys.contains(HKMetadataKeySyncVersion)
    }

    static func canRetryFinalization(
        sessionState: HKWorkoutSessionState
    ) -> Bool {
        [.stopped, .ended].contains(sessionState)
    }

    static func canAdoptRecoveredIdentity(
        sessionState: HKWorkoutSessionState
    ) -> Bool {
        [.running, .paused].contains(sessionState)
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            guard let self, workoutSession === session else { return }
            if let terminalCleanupSessionID,
               let terminalCleanupDisposition,
               let terminalBuilder = builder {
                handleTerminalTombstoneSessionState(
                    toState,
                    transitionDate: date,
                    disposition: terminalCleanupDisposition,
                    adapter: WatchTerminalSessionCleanupAdapter(
                        stopSession: { transitionDate in
                            workoutSession.stopActivity(with: transitionDate)
                        },
                        completeSession: { [weak self] disposition in
                            self?.completeTerminalTombstoneSessionCleanup(
                                workoutSession,
                                builder: terminalBuilder,
                                sessionID: terminalCleanupSessionID,
                                disposition: disposition
                            )
                        }
                    )
                )
                return
            }
            switch toState {
            case .running:
                switch WorkoutRunningCallbackPolicy.action(for: lifecycle.state) {
                case .enterRunning:
                    _ = lifecycle.apply(.sessionRunning)
                    routeRecorder.setPaused(false, at: date)
                    startPeriodicSnapshots()
                    publishSnapshotImmediately()
                case .stopSession:
                    stopSessionForFinalization(
                        workoutSession,
                        at: authoritativeFinalizationEndDate ?? date
                    )
                case .ignore:
                    break
                }
            case .paused:
                if lifecycle.state == .ending {
                    stopSessionForFinalization(
                        workoutSession,
                        at: authoritativeFinalizationEndDate ?? date
                    )
                    return
                }
                _ = lifecycle.apply(.sessionPaused)
                routeRecorder.setPaused(true, at: date)
                publishSnapshotImmediately()
            case .stopped, .ended:
                handleSessionReadyForFinalization(
                    at: workoutSession.endDate ?? date
                )
            case .notStarted, .prepared:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self, workoutSession === session else { return }
            if let terminalCleanupSessionID,
               let terminalCleanupDisposition,
               let terminalBuilder = builder {
                completeTerminalTombstoneSessionCleanup(
                    workoutSession,
                    builder: terminalBuilder,
                    sessionID: terminalCleanupSessionID,
                    disposition: terminalCleanupDisposition
                )
                return
            }
            lastErrorCode = Self.safeErrorCode(for: error)
            switch WorkoutSessionFailurePolicy.action(for: lifecycle.state) {
            case .failStart:
                handleStartFailure(error)
            case .savePartialWorkout:
                requestEnd(
                    .save,
                    requestedAt: workoutSession.endDate ?? Date()
                )
            case .finishRequestedDisposition:
                stopSessionForFinalization(
                    workoutSession,
                    at: authoritativeFinalizationEndDate
                        ?? workoutSession.endDate
                        ?? Date()
                )
            case .ignore:
                break
            }
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor [weak self] in
            guard let self, workoutBuilder === builder else { return }
            updateMetrics(
                from: workoutBuilder,
                collectedTypes: collectedTypes,
                capturedAt: Date()
            )
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {
        Task { @MainActor [weak self] in
            guard let self, workoutBuilder === builder else { return }
            scheduleCoalescedSnapshot()
        }
    }
}

private enum WorkoutFinalizationError: Error {
    case endCollectionFailed
    case finishWorkoutFailed
    case managerReleased
}
