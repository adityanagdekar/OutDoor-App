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

    private var consecutiveGoodFixes = 0
    private var consecutiveBadFixes = 0
    private var lastGoodFixDate: Date?
    @ObservationIgnored private var reliabilityTimeoutTask: Task<Void, Never>?

    /// Combines completed intervals with only the current interval's sensor delta.
    var displayedDistance: Double {
        committedDistance + currentIntervalDistance
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
        sessionState = .active

        locationService.requestWhenInUseAuthorization()
        motionService.requestAuthorization()

        let startDate = Date()
        motionService.startUpdates(from: startDate)
        locationService.suspendRouteRecording()
        locationService.startSession()
        evaluateDistanceSource()
    }

    /// Commits the current interval and pauses both sensor services.
    func pauseSession() {
        guard sessionState == .active else {
            return
        }

        commitCurrentInterval()
        cancelReliabilityTimeout()
        locationService.pauseSession()
        motionService.pauseUpdates()
        sessionState = .paused
    }

    /// Resumes both sensors and requires fresh evidence of GPS reliability.
    func resumeSession() {
        guard sessionState == .paused else {
            return
        }

        sessionState = .active
        activeDistanceSource = nil
        currentSourceBaseline = 0
        resetGPSReliability()

        let resumeDate = Date()
        motionService.resumeUpdates(from: resumeDate)
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
            commitCurrentInterval()
        }

        cancelReliabilityTimeout()
        locationService.endSession()
        motionService.stopUpdates()
        sessionState = .completed
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
            self?.sensorStateDidChange()
        }
    }

    /// Re-evaluates the active distance source whenever an owned sensor changes.
    private func sensorStateDidChange() {
        guard sessionState == .active else {
            return
        }

        evaluateDistanceSource()
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

    /// Prefers GPS only after reliability is established, otherwise using pedometer distance.
    private func evaluateDistanceSource() {
        guard sessionState == .active else {
            return
        }

        if gpsReliability == .reliable {
            selectDistanceSource(.gps)
        } else if isPedometerReady {
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
