import CoreMotion
import Foundation
import Observation

@MainActor
@Observable
final class OutdoorSessionService {
    enum SessionState: Equatable {
        /// The session screen is ready, but no sensor tracking has started.
        case ready

        /// The session is active and its sensor services are running.
        case active

        /// The session is preserved while sensor updates are stopped.
        case paused

        /// The session has ended and its final values are retained.
        case completed
    }

    enum MotionAvailability: Equatable {
        /// Pedometer data is available for walking detection and estimated distance.
        case available

        /// The system has not finished resolving Motion & Fitness authorization.
        case awaitingAuthorization

        /// Pedometer distance cannot be used on this device or with current permission.
        case unavailable
    }

    /// Number of sequential healthy fixes required before GPS supplies distance.
    static let requiredConsecutiveGoodFixes = 3

    /// Number of sequential unhealthy fixes required before abandoning GPS.
    static let requiredConsecutiveBadFixes = 3

    /// Longest allowed active-session interval without a healthy GPS fix.
    static let maximumTimeWithoutGoodFix: TimeInterval = 12

    /// Default verified-walking goal: 30 minutes.
    static let defaultGoalDuration: TimeInterval = 30 * 60

    /// Maximum age of a pedometer sample used as live movement evidence.
    static let maximumMotionUpdateAge: TimeInterval = 5

    /// Brief movement gaps that continue counting as walking, such as traffic lights.
    static let movementGracePeriod: TimeInterval = 75

    /// Sustained inactivity duration before offering Continue or End actions.
    static let stationaryWarningThreshold: TimeInterval = 3 * 60

    /// Longer inactivity duration used to present a stronger warning.
    static let prolongedInactivityThreshold: TimeInterval = 30 * 60

    /// Smallest forward pedometer distance change treated as movement.
    static let minimumMovementDistance: Double = 0.5

    /// Smallest positive live cadence treated as walking, in steps per second.
    static let minimumWalkingCadence: Double = 0.2

    /// Minimum interval between automatic active-session recovery snapshots.
    static let persistenceInterval: TimeInterval = 10

    let locationService: LocationService
    let motionService: MotionService

    private(set) var sessionState: SessionState = .ready
    private(set) var gpsReliability: GPSReliability = .acquiring
    private(set) var walkingActivityState: WalkingActivityState = .ready
    private(set) var shouldShowInactivityActions = false
    private(set) var hasProlongedInactivity = false
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var elapsedSessionTime: TimeInterval = 0
    private(set) var verifiedWalkingTime: TimeInterval = 0
    private(set) var stationaryTime: TimeInterval = 0
    private(set) var goalDuration: TimeInterval = OutdoorSessionService.defaultGoalDuration
    private(set) var sessionID: UUID?
    private(set) var sessionStartDate: Date?

    private let persistenceStore: OutdoorSessionPersistenceStore
    private var lastPersistenceDate: Date?
    private var consecutiveGoodFixes = 0
    private var consecutiveBadFixes = 0
    private var lastGoodFixDate: Date?
    private var lastTimeAccountingDate: Date?
    private var lastObservedStepCount = 0
    private var lastObservedPedometerDistance: Double = 0
    private var lastMovementEvidenceDate: Date?
    @ObservationIgnored private var reliabilityTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var timeAccountingTask: Task<Void, Never>?
    @ObservationIgnored private var movementTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var stationaryWarningTask: Task<Void, Never>?
    @ObservationIgnored private var prolongedInactivityTask: Task<Void, Never>?

    /// Returns the unearned portion of the current walking-time goal.
    var remainingTime: TimeInterval {
        max(goalDuration - verifiedWalkingTime, 0)
    }

    /// Uses Core Motion's walking-distance estimate as secondary session information.
    var estimatedDistance: Double {
        motionService.pedometerDistance
    }

    /// Describes whether Core Motion can verify walking and estimate distance.
    var motionAvailability: MotionAvailability {
        guard motionService.isDistanceAvailable else {
            return .unavailable
        }

        switch motionService.authorizationStatus {
        case .notDetermined:
            return .awaitingAuthorization
        case .denied, .restricted:
            return .unavailable
        case .authorized:
            return motionService.motionError == nil ? .available : .unavailable
        @unknown default:
            return .unavailable
        }
    }

    /// Creates a coordinator with newly constructed sensor services.
    init() {
        locationService = LocationService()
        motionService = MotionService()
        persistenceStore = OutdoorSessionPersistenceStore()
        configureSensorCallbacks()
        restorePersistedSessionIfAvailable()
    }

    /// Creates a coordinator with injected sensor services for testing or previews.
    init(
        locationService: LocationService,
        motionService: MotionService,
        persistenceStore: OutdoorSessionPersistenceStore = OutdoorSessionPersistenceStore()
    ) {
        self.locationService = locationService
        self.motionService = motionService
        self.persistenceStore = persistenceStore
        configureSensorCallbacks()
        restorePersistedSessionIfAvailable()
    }

    /// Requests a map-position fix without beginning an outdoor session.
    func requestMapLocation() {
        locationService.requestMapLocation()
    }

    /// Requests foreground location access through the owned location service.
    func requestLocationAuthorization() {
        locationService.requestWhenInUseAuthorization()
    }

    /// Requests permissions and starts a walking session that may continue in the background.
    func startSession() {
        guard sessionState == .ready || sessionState == .completed else {
            return
        }

        resetGPSReliability()
        resetTimeMetrics()
        refreshSystemConditions()
        sessionState = .active
        walkingActivityState = .acquiringMovement

        locationService.requestWhenInUseAuthorization()
        motionService.requestAuthorization()

        let startDate = Date()
        sessionID = UUID()
        sessionStartDate = startDate
        lastPersistenceDate = nil
        beginTimeAccounting(at: startDate)
        motionService.startUpdates(from: startDate)
        resetMovementDetection(at: startDate)
        locationService.startSession()
        persistSession(at: startDate, force: true)
    }

    /// Accounts through the pause timestamp, then pauses both sensor services.
    func pauseSession() {
        guard sessionState == .active else {
            return
        }

        updateTimeAccounting(at: Date())
        stopTimeAccounting()
        cancelMovementTimeout()
        cancelReliabilityTimeout()
        locationService.pauseSession()
        motionService.pauseUpdates()
        sessionState = .paused
        walkingActivityState = .paused
        persistSession(force: true)
        OutDoorLog.outdoorSession("SESSION_EXPLICITLY_PAUSED sensorsStopped=true")
    }

    /// Resumes both sensors with fresh movement baselines and GPS acquisition.
    func resumeSession() {
        guard sessionState == .paused else {
            return
        }

        sessionState = .active
        walkingActivityState = .acquiringMovement
        resetGPSReliability()

        let resumeDate = Date()
        beginTimeAccounting(at: resumeDate)
        motionService.resumeUpdates(from: resumeDate)
        resetMovementDetection(at: resumeDate)
        locationService.resumeSession()
        persistSession(at: resumeDate, force: true)
    }

    /// Finalizes earned walking time and stops both sensor streams.
    func endSession() async {
        guard sessionState == .active || sessionState == .paused else {
            return
        }

        if sessionState == .active {
            updateTimeAccounting(at: Date())
        }

        stopTimeAccounting()
        cancelMovementTimeout()
        cancelReliabilityTimeout()
        locationService.endSession()
        motionService.stopUpdates()
        sessionState = .completed
        walkingActivityState = .completed

        let completedSessionID = sessionID
        let completedWalkingTime = verifiedWalkingTime
        let completedAt = Date()
        OutDoorLog.outdoorSession(
            "SESSION_EXPLICITLY_ENDED sessionID=\(completedSessionID?.uuidString ?? "none") verifiedWalkingSeconds=\(completedWalkingTime) sensorsStopped=true"
        )

        if let completedSessionID, completedWalkingTime >= 60 {
            do {
                let entry = try await InstagramAccountingStore.shared.grantVerifiedWalkingCredit(
                    seconds: completedWalkingTime,
                    earnedAt: completedAt,
                    outdoorSessionID: completedSessionID
                )
                OutDoorLog.outdoorSession(
                    "SESSION_WALKING_CREDIT_COMMITTED sessionID=\(completedSessionID.uuidString) entryID=\(entry.id.uuidString) seconds=\(entry.durationSeconds)"
                )
            } catch {
                OutDoorLog.error(
                    "OutdoorSession",
                    "SESSION_WALKING_CREDIT_FAILED sessionID=\(completedSessionID.uuidString) error=\(error.localizedDescription)"
                )
                return
            }
        } else {
            OutDoorLog.outdoorSession(
                "SESSION_WALKING_CREDIT_SKIPPED sessionID=\(completedSessionID?.uuidString ?? "none") verifiedWalkingSeconds=\(completedWalkingTime) minimumSeconds=60"
            )
        }

        clearPersistedSession()
        sessionID = nil
        sessionStartDate = nil
        lastPersistenceDate = nil
    }

    /// Reconciles delayed timer delivery without pausing an active background session.
    func reconcileActiveSessionTime(at date: Date = Date()) {
        refreshSystemConditions()

        guard sessionState == .active else {
            return
        }

        updateTimeAccounting(at: date)
        persistSession(at: date, force: true)
    }

    /// Keeps an inactive session open without awarding time until walking resumes.
    func continueAfterInactivityWarning() {
        guard sessionState == .active,
              walkingActivityState == .stationary else {
            return
        }

        shouldShowInactivityActions = false
    }

    /// Retries GPS updates while leaving pedometer observation and interval totals intact.
    func retryLocationUpdates() {
        resetGPSReliability()
        locationService.retryLocationUpdates()
    }

    /// Connects sensor samples and failures to coordinator-owned reliability decisions.
    private func configureSensorCallbacks() {
        locationService.onGPSFixEvaluated = { [weak self] isGoodFix, observedAt in
            self?.recordGPSFix(isGood: isGoodFix, observedAt: observedAt)
        }

        locationService.onGPSFailure = { [weak self] in
            self?.recordGPSFailure()
        }

        motionService.onUpdate = { [weak self] in
            self?.motionStateDidChange()
        }
    }

    /// Uses fresh pedometer changes as the primary evidence of walking.
    private func motionStateDidChange() {
        guard sessionState == .active else {
            return
        }

        evaluatePedometerMovement()
        persistSession()
    }

    /// Updates consecutive-fix counters and promotes or demotes GPS reliability.
    private func recordGPSFix(isGood: Bool, observedAt: Date) {
        guard sessionState == .active else {
            return
        }

        // Location delivery also acts as a background wake-up checkpoint when
        // timer callbacks have been deferred by the system.
        updateTimeAccounting(at: observedAt)
        persistSession(at: observedAt)

        if isGood {
            consecutiveGoodFixes += 1
            consecutiveBadFixes = 0
            lastGoodFixDate = observedAt
            scheduleReliabilityTimeout(after: observedAt)

            if consecutiveGoodFixes >= Self.requiredConsecutiveGoodFixes {
                gpsReliability = .reliable
            } else if gpsReliability != .reliable {
                gpsReliability = .acquiring
            }
        } else {
            recordGPSFailure()
            return
        }

    }

    /// Counts one unhealthy fix or location error toward making GPS unreliable.
    private func recordGPSFailure() {
        guard sessionState == .active else {
            return
        }

        consecutiveGoodFixes = 0
        consecutiveBadFixes += 1

        if consecutiveBadFixes >= Self.requiredConsecutiveBadFixes {
            gpsReliability = .unreliable
        }

    }

    /// Establishes fresh pedometer baselines for a new active tracking interval.
    private func resetMovementDetection(at date: Date) {
        cancelMovementTimeout()
        lastObservedStepCount = motionService.stepCount
        lastObservedPedometerDistance = motionService.pedometerDistance
        lastMovementEvidenceDate = date
        shouldShowInactivityActions = false
        hasProlongedInactivity = false
        scheduleMovementTimeout(after: date)
    }

    /// Classifies fresh step, distance, or cadence changes as verified walking.
    private func evaluatePedometerMovement(at now: Date = Date()) {
        let stepCount = motionService.stepCount
        let distance = motionService.pedometerDistance
        let stepIncrease = stepCount > lastObservedStepCount
        let distanceIncrease = distance - lastObservedPedometerDistance
        let cadenceIndicatesWalking = (motionService.currentCadence ?? 0)
            >= Self.minimumWalkingCadence
        let updateIsRecent = motionService.lastUpdateDate.map {
            abs(now.timeIntervalSince($0)) <= Self.maximumMotionUpdateAge
        } ?? false

        lastObservedStepCount = stepCount
        lastObservedPedometerDistance = distance

        guard updateIsRecent,
              stepIncrease
                || distanceIncrease >= Self.minimumMovementDistance
                || cadenceIndicatesWalking else {
            return
        }

        let evidenceDate = motionService.lastUpdateDate ?? now

        // Account the preceding interval against the previous evidence first.
        // This prevents a delayed callback from retroactively marking a long
        // background gap as verified walking.
        setWalkingVerification(true, at: now)
        lastMovementEvidenceDate = evidenceDate
        shouldShowInactivityActions = false
        hasProlongedInactivity = false
        scheduleMovementTimeout(after: evidenceDate)
    }

    /// Restarts the configurable grace, warning, and prolonged-inactivity deadlines.
    private func scheduleMovementTimeout(after evidenceDate: Date) {
        cancelMovementTimeout()

        let evidenceAge = max(Date().timeIntervalSince(evidenceDate), 0)
        let remainingGracePeriod = max(
            Self.movementGracePeriod - evidenceAge,
            0
        )
        let remainingWarningPeriod = max(
            Self.stationaryWarningThreshold - evidenceAge,
            0
        )
        let remainingProlongedPeriod = max(
            Self.prolongedInactivityThreshold - evidenceAge,
            0
        )

        movementTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remainingGracePeriod))

            guard !Task.isCancelled else {
                return
            }

            self?.handleMovementTimeout(expectedEvidenceDate: evidenceDate)
        }

        stationaryWarningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remainingWarningPeriod))

            guard !Task.isCancelled else {
                return
            }

            self?.handleStationaryWarning(expectedEvidenceDate: evidenceDate)
        }

        prolongedInactivityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remainingProlongedPeriod))

            guard !Task.isCancelled else {
                return
            }

            self?.handleProlongedInactivity(expectedEvidenceDate: evidenceDate)
        }
    }

    /// Stops earning walking time after the movement grace period expires.
    private func handleMovementTimeout(expectedEvidenceDate: Date) {
        guard sessionState == .active,
              lastMovementEvidenceDate == expectedEvidenceDate else {
            return
        }

        setWalkingVerification(false)
    }

    /// Offers Continue and End after sustained inactivity.
    private func handleStationaryWarning(expectedEvidenceDate: Date) {
        guard sessionState == .active,
              walkingActivityState == .stationary,
              lastMovementEvidenceDate == expectedEvidenceDate else {
            return
        }

        shouldShowInactivityActions = true
    }

    /// Strengthens the warning after the longer configurable inactivity threshold.
    private func handleProlongedInactivity(expectedEvidenceDate: Date) {
        guard sessionState == .active,
              walkingActivityState == .stationary,
              lastMovementEvidenceDate == expectedEvidenceDate else {
            return
        }

        hasProlongedInactivity = true
        shouldShowInactivityActions = true
    }

    /// Cancels all pending inactivity transitions while the session is not active.
    private func cancelMovementTimeout() {
        movementTimeoutTask?.cancel()
        movementTimeoutTask = nil
        stationaryWarningTask?.cancel()
        stationaryWarningTask = nil
        prolongedInactivityTask?.cancel()
        prolongedInactivityTask = nil
    }

    /// Resets all time measurements before a new session begins.
    private func resetTimeMetrics() {
        stopTimeAccounting()
        elapsedSessionTime = 0
        verifiedWalkingTime = 0
        stationaryTime = 0
        shouldShowInactivityActions = false
        hasProlongedInactivity = false
        walkingActivityState = .ready
    }

    /// Starts a timestamp-based ticker; correctness does not depend on one-second delivery.
    private func beginTimeAccounting(at date: Date) {
        stopTimeAccounting()
        lastTimeAccountingDate = date

        timeAccountingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))

                guard !Task.isCancelled else {
                    return
                }

                self?.updateTimeAccounting(at: Date())
            }
        }
    }

    /// Assigns elapsed active time to either verified walking or stationary time.
    private func updateTimeAccounting(at date: Date) {
        guard sessionState == .active,
              let lastTimeAccountingDate else {
            return
        }

        let elapsed = date.timeIntervalSince(lastTimeAccountingDate)

        guard elapsed.isFinite, elapsed > 0 else {
            return
        }

        elapsedSessionTime += elapsed

        switch walkingActivityState {
        case .walking:
            let verificationDeadline = lastMovementEvidenceDate?
                .addingTimeInterval(Self.movementGracePeriod)
                ?? lastTimeAccountingDate
            let verifiedEnd = min(date, verificationDeadline)
            let verifiedInterval = max(
                0,
                verifiedEnd.timeIntervalSince(lastTimeAccountingDate)
            )

            verifiedWalkingTime += min(verifiedInterval, elapsed)
            stationaryTime += max(0, elapsed - verifiedInterval)

            if date >= verificationDeadline {
                walkingActivityState = .stationary
            }
        case .acquiringMovement, .stationary:
            stationaryTime += elapsed
        case .ready, .paused, .completed:
            break
        }

        self.lastTimeAccountingDate = date
        persistSession(at: date)
    }

    /// Changes the walking classification without losing time at the transition.
    func setWalkingVerification(_ isVerified: Bool, at date: Date = Date()) {
        guard sessionState == .active else {
            return
        }

        updateTimeAccounting(at: date)
        walkingActivityState = isVerified ? .walking : .stationary
    }

    /// Stops accounting so explicitly paused and completed time cannot be counted.
    private func stopTimeAccounting() {
        timeAccountingTask?.cancel()
        timeAccountingTask = nil
        lastTimeAccountingDate = nil
    }

    /// Clears reliability evidence before a new active tracking period.
    private func resetGPSReliability() {
        cancelReliabilityTimeout()
        gpsReliability = .acquiring
        consecutiveGoodFixes = 0
        consecutiveBadFixes = 0
        lastGoodFixDate = nil
    }

    /// Restarts the deadline that detects a prolonged gap without a healthy fix.
    private func scheduleReliabilityTimeout(after fixDate: Date) {
        cancelReliabilityTimeout()

        reliabilityTimeoutTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(Self.maximumTimeWithoutGoodFix)
            )

            guard !Task.isCancelled else {
                return
            }

            self?.handleReliabilityTimeout(expectedLastFix: fixDate)
        }
    }

    /// Marks GPS unreliable if no newer healthy fix arrived before the deadline.
    private func handleReliabilityTimeout(expectedLastFix: Date) {
        guard sessionState == .active,
              lastGoodFixDate == expectedLastFix else {
            return
        }

        consecutiveGoodFixes = 0
        consecutiveBadFixes = Self.requiredConsecutiveBadFixes
        gpsReliability = .unreliable
    }

    /// Cancels the pending no-fix deadline when tracking pauses or stops.
    private func cancelReliabilityTimeout() {
        reliabilityTimeoutTask?.cancel()
        reliabilityTimeoutTask = nil
    }

    /// Saves a compact recovery snapshot at a controlled interval.
    private func persistSession(at date: Date = Date(), force: Bool = false) {
        guard sessionState == .active || sessionState == .paused,
              let sessionID,
              let sessionStartDate else {
            return
        }

        if !force,
           let lastPersistenceDate,
           date.timeIntervalSince(lastPersistenceDate) < Self.persistenceInterval {
            return
        }

        let snapshot = OutdoorSessionSnapshot(
            sessionID: sessionID,
            startTimestamp: sessionStartDate,
            savedAt: date,
            elapsedSessionTime: max(0, elapsedSessionTime),
            verifiedWalkingTime: max(0, verifiedWalkingTime),
            stationaryTime: max(0, stationaryTime),
            lastMovementTimestamp: lastMovementEvidenceDate,
            pedometerStepBaseline: max(0, lastObservedStepCount),
            pedometerDistanceBaseline: max(0, lastObservedPedometerDistance),
            estimatedDistance: max(0, estimatedDistance),
            activityState: walkingActivityState,
            wasPaused: sessionState == .paused
        )

        do {
            try persistenceStore.save(snapshot)
            lastPersistenceDate = date
            OutDoorLog.outdoorSession(
                "SESSION_SNAPSHOT_SAVED id=\(sessionID.uuidString) verifiedSeconds=\(snapshot.verifiedWalkingTime) distance=\(snapshot.estimatedDistance) activity=\(snapshot.activityState.rawValue)"
            )
        } catch {
            OutDoorLog.error(
                "OutdoorSession",
                "SESSION_SNAPSHOT_SAVE_FAILED id=\(sessionID.uuidString) error=\(error.localizedDescription)"
            )
        }
    }

    /// Restores a terminated session as paused so unavailable time is never rewarded.
    private func restorePersistedSessionIfAvailable() {
        do {
            guard let snapshot = try persistenceStore.load() else {
                return
            }

            sessionID = snapshot.sessionID
            sessionStartDate = snapshot.startTimestamp
            elapsedSessionTime = max(0, snapshot.elapsedSessionTime)
            verifiedWalkingTime = max(0, snapshot.verifiedWalkingTime)
            stationaryTime = max(0, snapshot.stationaryTime)
            lastMovementEvidenceDate = snapshot.lastMovementTimestamp
            lastObservedStepCount = max(0, snapshot.pedometerStepBaseline)
            lastObservedPedometerDistance = max(0, snapshot.pedometerDistanceBaseline)
            lastPersistenceDate = snapshot.savedAt

            motionService.restorePausedMeasurements(
                stepCount: snapshot.pedometerStepBaseline,
                distance: snapshot.estimatedDistance,
                lastUpdateDate: snapshot.lastMovementTimestamp
            )
            locationService.restorePausedSession()
            sessionState = .paused
            walkingActivityState = .paused
            resetGPSReliability()

            OutDoorLog.outdoorSession(
                "SESSION_SNAPSHOT_RESTORED id=\(snapshot.sessionID.uuidString) savedActivity=\(snapshot.activityState.rawValue) verifiedSeconds=\(verifiedWalkingTime) distance=\(estimatedDistance)"
            )
        } catch {
            OutDoorLog.error(
                "OutdoorSession",
                "SESSION_SNAPSHOT_RESTORE_FAILED error=\(error.localizedDescription)"
            )
        }
    }

    /// Refreshes system conditions that can affect background update frequency.
    private func refreshSystemConditions() {
        let lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard lowPowerModeEnabled != isLowPowerModeEnabled else {
            return
        }

        isLowPowerModeEnabled = lowPowerModeEnabled
        OutDoorLog.outdoorSession(
            "LOW_POWER_MODE_CHANGED enabled=\(lowPowerModeEnabled)"
        )
    }

    /// Removes recovery data once the user explicitly completes the session.
    private func clearPersistedSession() {
        do {
            try persistenceStore.clear()
            OutDoorLog.outdoorSession("SESSION_SNAPSHOT_CLEARED")
        } catch {
            OutDoorLog.error(
                "OutdoorSession",
                "SESSION_SNAPSHOT_CLEAR_FAILED error=\(error.localizedDescription)"
            )
        }
    }

}
