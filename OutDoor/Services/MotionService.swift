@preconcurrency import CoreMotion
import Foundation
import Observation

@MainActor
@Observable
final class MotionService {
    enum ActivityState: Equatable {
        /// No pedometer update stream is running.
        case inactive

        /// Live pedometer updates are being received for the current session.
        case active

        /// Updates are stopped while the accumulated session values remain available.
        case paused
    }

    enum MotionError: LocalizedError, Equatable {
        case unavailable
        case permissionDenied
        case updatesFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Step counting and pedometer distance are unavailable on this device."
            case .permissionDenied:
                "Motion access is denied. Enable Motion & Fitness access in Settings."
            case .updatesFailed(let message):
                "Motion tracking failed: \(message)"
            }
        }
    }

    private(set) var authorizationStatus: CMAuthorizationStatus
    private(set) var isStepCountingAvailable: Bool
    private(set) var isDistanceAvailable: Bool
    private(set) var isCadenceAvailable: Bool
    private(set) var stepCount = 0
    private(set) var pedometerDistance: Double = 0
    private(set) var currentCadence: Double?
    private(set) var lastUpdateDate: Date?
    private(set) var motionError: MotionError?
    private(set) var activityState: ActivityState = .inactive

    private let pedometer: CMPedometer
    private var committedStepCount = 0
    private var committedDistance: Double = 0
    private var intervalStepCount = 0
    private var intervalDistance: Double = 0
    private var updateGeneration = 0
    @ObservationIgnored var onUpdate: (() -> Void)?

    /// Creates a pedometer service and records the device's motion capabilities.
    init() {
        pedometer = CMPedometer()
        authorizationStatus = CMPedometer.authorizationStatus()
        isStepCountingAvailable = CMPedometer.isStepCountingAvailable()
        isDistanceAvailable = CMPedometer.isDistanceAvailable()
        isCadenceAvailable = CMPedometer.isCadenceAvailable()
    }

    /// Triggers the system Motion & Fitness permission prompt when authorization is undecided.
    func requestAuthorization() {
        refreshAuthorizationStatus()

        guard isStepCountingAvailable || isDistanceAvailable else {
            motionError = .unavailable
            return
        }

        guard authorizationStatus == .notDetermined else {
            updateErrorForAuthorizationStatus()
            return
        }

        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-1)

        pedometer.queryPedometerData(from: startDate, to: endDate) { [weak self] _, error in
            let message = error?.localizedDescription

            Task { @MainActor in
                self?.finishAuthorizationRequest(errorMessage: message)
            }
        }
    }

    /// Starts a fresh pedometer session and resets all previously accumulated values.
    func startUpdates(from startDate: Date) {
        stopPedometerStream()
        resetMeasurements()
        refreshAuthorizationStatus()

        guard canStartUpdates else {
            onUpdate?()
            return
        }

        startPedometerStream(from: startDate)
        onUpdate?()
    }

    /// Pauses pedometer delivery while preserving the session's accumulated values.
    func pauseUpdates() {
        guard activityState == .active else {
            return
        }

        commitCurrentInterval()
        stopPedometerStream()
        activityState = .paused
    }

    /// Resumes pedometer delivery as a new interval without resetting earlier session values.
    func resumeUpdates(from startDate: Date) {
        guard activityState == .paused else {
            return
        }

        refreshAuthorizationStatus()

        guard canStartUpdates else {
            onUpdate?()
            return
        }

        startPedometerStream(from: startDate)
        onUpdate?()
    }

    /// Restores saved measurements as a paused baseline after process recovery.
    func restorePausedMeasurements(
        stepCount: Int,
        distance: Double,
        lastUpdateDate: Date?
    ) {
        stopPedometerStream()
        committedStepCount = max(stepCount, 0)
        committedDistance = max(distance, 0)
        intervalStepCount = 0
        intervalDistance = 0
        self.stepCount = committedStepCount
        pedometerDistance = committedDistance
        currentCadence = nil
        self.lastUpdateDate = lastUpdateDate
        motionError = nil
        activityState = .paused
        onUpdate?()
    }

    /// Stops pedometer delivery and preserves the final values for session results.
    func stopUpdates() {
        if activityState == .active {
            commitCurrentInterval()
        }

        stopPedometerStream()
        activityState = .inactive
    }

    /// Starts one update interval and tags callbacks so stopped streams cannot change state.
    private func startPedometerStream(from startDate: Date) {
        motionError = nil
        intervalStepCount = 0
        intervalDistance = 0
        activityState = .active
        updateGeneration += 1
        let generation = updateGeneration

        pedometer.startUpdates(from: startDate) { [weak self] data, error in
            let steps = data?.numberOfSteps.intValue
            let measuredDistance = data?.distance?.doubleValue
            let cadence = data?.currentCadence?.doubleValue
            let updateDate = data?.endDate
            let message = error?.localizedDescription

            Task { @MainActor in
                self?.receive(
                    steps: steps,
                    distance: measuredDistance,
                    cadence: cadence,
                    updateDate: updateDate,
                    errorMessage: message,
                    generation: generation
                )
            }
        }
    }

    /// Applies cumulative values from the current interval to the observable session totals.
    private func receive(
        steps: Int?,
        distance measuredDistance: Double?,
        cadence: Double?,
        updateDate: Date?,
        errorMessage: String?,
        generation: Int
    ) {
        guard generation == updateGeneration, activityState == .active else {
            return
        }

        refreshAuthorizationStatus()

        if let errorMessage {
            motionError = authorizationStatus == .denied
                ? .permissionDenied
                : .updatesFailed(errorMessage)
            onUpdate?()
            return
        }

        intervalStepCount = max(steps ?? 0, 0)
        intervalDistance = max(measuredDistance ?? 0, 0)
        stepCount = committedStepCount + intervalStepCount
        pedometerDistance = committedDistance + intervalDistance
        currentCadence = cadence.map { max($0, 0) }
        lastUpdateDate = updateDate
        motionError = nil
        onUpdate?()
    }

    /// Moves the latest interval values into the preserved session totals exactly once.
    private func commitCurrentInterval() {
        committedStepCount += intervalStepCount
        committedDistance += intervalDistance
        intervalStepCount = 0
        intervalDistance = 0
        stepCount = committedStepCount
        pedometerDistance = committedDistance
    }

    /// Invalidates pending callbacks and stops Core Motion's live update stream.
    private func stopPedometerStream() {
        updateGeneration += 1
        pedometer.stopUpdates()
    }

    /// Clears all step and distance values before a new session begins.
    private func resetMeasurements() {
        committedStepCount = 0
        committedDistance = 0
        intervalStepCount = 0
        intervalDistance = 0
        stepCount = 0
        pedometerDistance = 0
        currentCadence = nil
        lastUpdateDate = nil
        motionError = nil
        activityState = .inactive
    }

    /// Refreshes the authorization value exposed to the UI.
    private func refreshAuthorizationStatus() {
        authorizationStatus = CMPedometer.authorizationStatus()
    }

    /// Finishes the permission probe and reports denial or query failures.
    private func finishAuthorizationRequest(errorMessage: String?) {
        refreshAuthorizationStatus()

        if authorizationStatus == .denied {
            motionError = .permissionDenied
        } else if let errorMessage {
            motionError = .updatesFailed(errorMessage)
        } else {
            motionError = nil
        }

        onUpdate?()
    }

    /// Converts the current authorization result into a user-facing service error.
    private func updateErrorForAuthorizationStatus() {
        switch authorizationStatus {
        case .denied:
            motionError = .permissionDenied
        case .restricted:
            motionError = .updatesFailed("Motion & Fitness access is restricted on this device.")
        case .authorized, .notDetermined:
            motionError = nil
        @unknown default:
            motionError = .updatesFailed("Motion authorization has an unknown status.")
        }
    }

    /// Checks device capability and authorization before starting an update stream.
    private var canStartUpdates: Bool {
        guard isStepCountingAvailable || isDistanceAvailable else {
            motionError = .unavailable
            activityState = .inactive
            return false
        }

        switch authorizationStatus {
        case .denied:
            motionError = .permissionDenied
            activityState = .inactive
            return false
        case .restricted:
            motionError = .updatesFailed("Motion & Fitness access is restricted on this device.")
            activityState = .inactive
            return false
        case .authorized, .notDetermined:
            return true
        @unknown default:
            motionError = .updatesFailed("Motion authorization has an unknown status.")
            activityState = .inactive
            return false
        }
    }
}
