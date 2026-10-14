import CoreLocation
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

    enum MotionFallbackAvailability: Equatable {
        /// Pedometer distance can be used when GPS becomes unreliable.
        case available

        /// The system has not finished resolving Motion & Fitness authorization.
        case awaitingAuthorization

        /// Pedometer distance cannot be used on this device or with current permission.
        case unavailable
    }

    struct DistanceInterval: Equatable {
        let source: DistanceSource
        let baseline: Double
        let endReading: Double

        /// Returns only the forward distance measured during this source interval.
        var distance: Double {
            max(endReading - baseline, 0)
        }
    }

    /// Number of sequential healthy fixes required before GPS supplies distance.
    static let requiredConsecutiveGoodFixes = 3

    /// Number of sequential unhealthy fixes required before abandoning GPS.
    static let requiredConsecutiveBadFixes = 3

    /// Longest allowed foreground interval without a healthy GPS fix.
    static let maximumTimeWithoutGoodFix: TimeInterval = 12

    /// Default verified-walking goal: 30 minutes.
    static let defaultGoalDuration: TimeInterval = 30 * 60

    /// Maximum age of a pedometer sample used as live movement evidence.
    static let maximumMotionUpdateAge: TimeInterval = 5

    /// Time without fresh walking evidence before the session becomes stationary.
    static let movementEvidenceTimeout: TimeInterval = 8

    /// Smallest forward pedometer distance change treated as movement.
    static let minimumMovementDistance: Double = 0.5

    /// Smallest positive live cadence treated as walking, in steps per second.
    static let minimumWalkingCadence: Double = 0.2

    let locationService: LocationService
    let motionService: MotionService

    private(set) var sessionState: SessionState = .ready
    private(set) var activeDistanceSource: DistanceSource?
    private(set) var committedDistance: Double = 0
    private(set) var currentSourceBaseline: Double = 0
    private(set) var gpsBaseline: Double = 0
    private(set) var pedometerBaseline: Double = 0
    private(set) var completedIntervals: [DistanceInterval] = []
    private(set) var gpsReliability: GPSReliability = .acquiring
    private(set) var walkingActivityState: WalkingActivityState = .ready
    private(set) var elapsedSessionTime: TimeInterval = 0
    private(set) var verifiedWalkingTime: TimeInterval = 0
    private(set) var stationaryTime: TimeInterval = 0
    private(set) var goalDuration: TimeInterval = OutdoorSessionService.defaultGoalDuration

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

    /// Combines completed intervals with only the current interval's sensor delta.
    var displayedDistance: Double {
        committedDistance + currentIntervalDistance
    }

    /// Returns the unearned portion of the current walking-time goal.
    var remainingTime: TimeInterval {
        max(goalDuration - verifiedWalkingTime, 0)
    }

    /// Uses Core Motion's walking-distance estimate as secondary session information.
    var estimatedDistance: Double {
        motionService.pedometerDistance
    }

    /// Describes whether pedometer distance can cover an unreliable GPS interval.
    var motionFallbackAvailability: MotionFallbackAvailability {
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
        configureSensorCallbacks()
    }

    /// Creates a coordinator with injected sensor services for testing or previews.
    init(
        locationService: LocationService,
        motionService: MotionService
    ) {
        self.locationService = locationService
        self.motionService = motionService
        configureSensorCallbacks()
    }

    /// Requests a map-position fix without beginning an outdoor session.
    func requestMapLocation() {
        locationService.requestMapLocation()
    }

    /// Requests foreground location access through the owned location service.
    func requestLocationAuthorization() {
        locationService.requestWhenInUseAuthorization()
    }

    /// Requests permissions, starts both sensors, and begins acquiring GPS reliability.
    func startSession() {
        guard sessionState == .ready || sessionState == .completed else {
            return
        }

        resetDistanceIntervals()
        resetGPSReliability()
        resetTimeMetrics()
        sessionState = .active
        walkingActivityState = .acquiringMovement

        locationService.requestWhenInUseAuthorization()
        motionService.requestAuthorization()

        let startDate = Date()
        beginTimeAccounting(at: startDate)
        motionService.startUpdates(from: startDate)
        resetMovementDetection(at: startDate)
        locationService.suspendRouteRecording()
        locationService.startSession()
        evaluateDistanceSource()
    }

    /// Commits the current interval and pauses both sensor services.
    func pauseSession() {
        guard sessionState == .active else {
            return
        }

        updateTimeAccounting(at: Date())
        stopTimeAccounting()
        cancelMovementTimeout()
        commitCurrentInterval()
        cancelReliabilityTimeout()
        locationService.pauseSession()
        motionService.pauseUpdates()
        sessionState = .paused
        walkingActivityState = .paused
    }

    /// Resumes both sensors and requires fresh evidence of GPS reliability.
    func resumeSession() {
        guard sessionState == .paused else {
            return
        }

        sessionState = .active
        walkingActivityState = .acquiringMovement
        activeDistanceSource = nil
        currentSourceBaseline = 0
        resetGPSReliability()

        let resumeDate = Date()
        beginTimeAccounting(at: resumeDate)
        motionService.resumeUpdates(from: resumeDate)
        resetMovementDetection(at: resumeDate)
        pedometerBaseline = motionService.pedometerDistance
        locationService.suspendRouteRecording()
        locationService.resumeSession()
        evaluateDistanceSource()
    }

    /// Commits the final interval and stops both sensor streams.
    func endSession() {
        guard sessionState == .active || sessionState == .paused else {
            return
        }

        if sessionState == .active {
            updateTimeAccounting(at: Date())
            commitCurrentInterval()
        }

        stopTimeAccounting()
        cancelMovementTimeout()
        cancelReliabilityTimeout()
        locationService.endSession()
        motionService.stopUpdates()
        sessionState = .completed
        walkingActivityState = .completed
    }

    /// Retries GPS updates while leaving pedometer observation and interval totals intact.
    func retryLocationUpdates() {
        resetGPSReliability()
        locationService.retryLocationUpdates()
        evaluateDistanceSource()
    }

    /// Connects sensor samples and failures to coordinator-owned reliability decisions.
    private func configureSensorCallbacks() {
        locationService.onUpdate = { [weak self] in
            self?.sensorStateDidChange()
        }

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

    /// Re-evaluates GPS support state whenever location data changes.
    private func sensorStateDidChange() {
        guard sessionState == .active else {
            return
        }

        evaluateDistanceSource()
    }

    /// Uses fresh pedometer changes as the primary evidence of walking.
    private func motionStateDidChange() {
        guard sessionState == .active else {
            return
        }

        evaluateDistanceSource()
        evaluatePedometerMovement()
    }

    /// Updates consecutive-fix counters and promotes or demotes GPS reliability.
    private func recordGPSFix(isGood: Bool, observedAt: Date) {
        guard sessionState == .active else {
            return
        }

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

        evaluateDistanceSource()
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

        evaluateDistanceSource()
    }

    /// Uses pedometer distance for session estimates while GPS remains supporting context.
    private func evaluateDistanceSource() {
        guard sessionState == .active else {
            return
        }

        if isPedometerReady {
            selectDistanceSource(.pedometer)
        } else if activeDistanceSource != nil {
            commitCurrentInterval()
        }
    }

    /// Ends the previous interval before beginning a new source at its current reading.
    private func selectDistanceSource(_ source: DistanceSource) {
        guard source != activeDistanceSource else {
            return
        }

        commitCurrentInterval()
        activeDistanceSource = source
        currentSourceBaseline = reading(for: source)

        switch source {
        case .gps:
            gpsBaseline = currentSourceBaseline
            locationService.resumeRouteRecordingAtNextReliableFix()
        case .pedometer:
            pedometerBaseline = currentSourceBaseline
            locationService.suspendRouteRecording()
        }
    }

    /// Finalizes exactly one source interval and adds its delta to committed distance.
    private func commitCurrentInterval() {
        guard let source = activeDistanceSource else {
            return
        }

        let interval = DistanceInterval(
            source: source,
            baseline: currentSourceBaseline,
            endReading: reading(for: source)
        )

        completedIntervals.append(interval)
        committedDistance += interval.distance
        activeDistanceSource = nil
        currentSourceBaseline = 0
    }

    /// Establishes fresh pedometer baselines for a new active tracking interval.
    private func resetMovementDetection(at date: Date) {
        cancelMovementTimeout()
        lastObservedStepCount = motionService.stepCount
        lastObservedPedometerDistance = motionService.pedometerDistance
        lastMovementEvidenceDate = date
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
        lastMovementEvidenceDate = evidenceDate
        setWalkingVerification(true, at: now)
        scheduleMovementTimeout(after: evidenceDate)
    }

    /// Restarts the deadline used to identify when verified movement has stopped.
    private func scheduleMovementTimeout(after evidenceDate: Date) {
        cancelMovementTimeout()

        movementTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.movementEvidenceTimeout))

            guard !Task.isCancelled else {
                return
            }

            self?.handleMovementTimeout(expectedEvidenceDate: evidenceDate)
        }
    }

    /// Changes the active session to stationary when no newer movement evidence arrived.
    private func handleMovementTimeout(expectedEvidenceDate: Date) {
        guard sessionState == .active,
              lastMovementEvidenceDate == expectedEvidenceDate else {
            return
        }

        setWalkingVerification(false)
    }

    /// Cancels movement classification work while the session is not active.
    private func cancelMovementTimeout() {
        movementTimeoutTask?.cancel()
        movementTimeoutTask = nil
    }

    /// Resets all time measurements before a new session begins.
    private func resetTimeMetrics() {
        stopTimeAccounting()
        elapsedSessionTime = 0
        verifiedWalkingTime = 0
        stationaryTime = 0
        walkingActivityState = .ready
    }

    /// Starts a foreground-only ticker for active-session time accounting.
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
            verifiedWalkingTime += elapsed
        case .acquiringMovement, .stationary:
            stationaryTime += elapsed
        case .ready, .paused, .completed:
            break
        }

        self.lastTimeAccountingDate = date
    }

    /// Changes the walking classification without losing time at the transition.
    func setWalkingVerification(_ isVerified: Bool, at date: Date = Date()) {
        guard sessionState == .active else {
            return
        }

        updateTimeAccounting(at: date)
        walkingActivityState = isVerified ? .walking : .stationary
    }

    /// Stops the timer so paused, background, and completed time cannot be counted.
    private func stopTimeAccounting() {
        timeAccountingTask?.cancel()
        timeAccountingTask = nil
        lastTimeAccountingDate = nil
    }

    /// Clears source history so a new session always begins at zero distance.
    private func resetDistanceIntervals() {
        completedIntervals = []
        committedDistance = 0
        activeDistanceSource = nil
        currentSourceBaseline = 0
        gpsBaseline = 0
        pedometerBaseline = 0
    }

    /// Clears reliability evidence before a new foreground tracking period.
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
        evaluateDistanceSource()
    }

    /// Cancels the pending no-fix deadline when tracking pauses or stops.
    private func cancelReliabilityTimeout() {
        reliabilityTimeoutTask?.cancel()
        reliabilityTimeoutTask = nil
    }

    /// Returns the uncommitted delta from the current interval's single source.
    private var currentIntervalDistance: Double {
        guard let activeDistanceSource else {
            return 0
        }

        return max(reading(for: activeDistanceSource) - currentSourceBaseline, 0)
    }

    /// Reports whether Core Motion can currently provide pedometer distance.
    private var isPedometerReady: Bool {
        motionService.isDistanceAvailable
            && motionService.authorizationStatus == .authorized
            && motionService.activityState == .active
            && motionService.motionError == nil
    }

    /// Returns one sensor's cumulative reading without combining it with another source.
    private func reading(for source: DistanceSource) -> Double {
        switch source {
        case .gps:
            locationService.gpsRouteDistance
        case .pedometer:
            motionService.pedometerDistance
        }
    }
}
