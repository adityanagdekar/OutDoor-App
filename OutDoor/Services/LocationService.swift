@preconcurrency import CoreLocation
import Observation

@MainActor
@Observable
final class LocationService: NSObject {
    enum LocationError: LocalizedError, Equatable {
        case servicesDisabled
        case updatesFailed(String)

        var errorDescription: String? {
            switch self {
            case .servicesDisabled:
                "Location Services are unavailable. Enable them in Settings to track your outdoor session."
            case .updatesFailed(let message):
                "Location tracking failed: \(message)"
            }
        }
    }

    private(set) var trackingState: TrackingState
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var latestLocation: CLLocation?
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var totalDistance: CLLocationDistance = 0
    private(set) var horizontalAccuracy: CLLocationAccuracy?
    private(set) var locationError: LocationError?

    private let locationManager: CLLocationManager
    private var isSessionActive = false

    /// Creates and configures the Core Location manager for foreground fitness tracking.
    override init() {
        let manager = CLLocationManager()
        locationManager = manager
        authorizationStatus = manager.authorizationStatus
        trackingState = Self.initialState(for: manager.authorizationStatus)

        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
    }

    /// Requests foreground location permission if the user has not responded yet.
    func requestWhenInUseAuthorization() {
        guard locationManager.authorizationStatus == .notDetermined else {
            handleAuthorizationChange(locationManager.authorizationStatus)
            return
        }

        locationManager.requestWhenInUseAuthorization()
    }

    /// Starts a new session after clearing location data from the previous session.
    func startSession() {
        stopLocationUpdates()
        resetSession()
        isSessionActive = true
        beginTrackingIfPossible()
    }

    /// Pauses the active session and stops location updates without clearing its route.
    func pauseSession() {
        guard isSessionActive else {
            return
        }

        stopLocationUpdates()
        trackingState = .paused
    }

    /// Resumes location updates for a paused session when authorization permits.
    func resumeSession() {
        guard isSessionActive, trackingState == .paused else {
            return
        }

        beginTrackingIfPossible()
    }

    /// Retries location updates after a temporary availability failure.
    func retryLocationUpdates() {
        guard isSessionActive else {
            return
        }

        beginTrackingIfPossible()
    }

    /// Completes the active session and stops all location updates.
    func endSession() {
        guard isSessionActive else {
            return
        }

        isSessionActive = false
        stopLocationUpdates()
        trackingState = .completed
    }

    /// Starts location updates or exposes the permission or availability issue preventing them.
    private func beginTrackingIfPossible() {
        locationError = nil

        guard CLLocationManager.locationServicesEnabled() else {
            stopLocationUpdates()
            trackingState = .locationUnavailable
            locationError = .servicesDisabled
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            stopLocationUpdates()
            trackingState = .permissionNotRequested
        case .denied:
            stopLocationUpdates()
            trackingState = .permissionDenied
        case .restricted:
            stopLocationUpdates()
            trackingState = .permissionRestricted
        case .authorizedWhenInUse, .authorizedAlways:
            trackingState = .waitingForAccurateFix
            locationManager.startUpdatingLocation()
        @unknown default:
            stopLocationUpdates()
            trackingState = .locationUnavailable
        }
    }

    /// Updates service state and tracking behavior after location authorization changes.
    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status

        switch status {
        case .notDetermined:
            stopLocationUpdates()
            trackingState = .permissionNotRequested
        case .denied:
            stopLocationUpdates()
            trackingState = .permissionDenied
        case .restricted:
            stopLocationUpdates()
            trackingState = .permissionRestricted
        case .authorizedWhenInUse, .authorizedAlways:
            if isSessionActive {
                beginTrackingIfPossible()
            } else if trackingState != .completed {
                trackingState = .paused
            }
        @unknown default:
            stopLocationUpdates()
            trackingState = .locationUnavailable
        }
    }

    /// Validates incoming locations and records only accepted route points.
    private func receive(_ locations: [CLLocation]) {
        guard isSessionActive,
              trackingState == .waitingForAccurateFix || trackingState == .tracking else {
            return
        }

        let now = Date()

        for location in locations {
            horizontalAccuracy = location.horizontalAccuracy

            guard let segmentDistance = LocationValidator.acceptedSegmentDistance(
                for: location,
                after: latestLocation,
                now: now
            ) else {
                continue
            }

            totalDistance += segmentDistance
            latestLocation = location
            routeCoordinates.append(location.coordinate)
            trackingState = .tracking
            locationError = nil
        }
    }

    /// Handles transient and terminal errors reported by Core Location.
    private func handleLocationFailure(
        code: CLError.Code?,
        message: String
    ) {
        guard isSessionActive else {
            return
        }

        if code == .locationUnknown {
            if latestLocation == nil {
                trackingState = .waitingForAccurateFix
            }
            return
        }

        stopLocationUpdates()
        trackingState = .locationUnavailable
        locationError = .updatesFailed(message)
    }

    /// Clears all route, distance, accuracy, and error data for a new session.
    private func resetSession() {
        latestLocation = nil
        routeCoordinates = []
        totalDistance = 0
        horizontalAccuracy = nil
        locationError = nil
    }

    /// Stops the underlying Core Location update stream.
    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
    }

    /// Maps the current authorization status to the service's initial tracking state.
    private static func initialState(for status: CLAuthorizationStatus) -> TrackingState {
        switch status {
        case .notDetermined:
            .permissionNotRequested
        case .denied:
            .permissionDenied
        case .restricted:
            .permissionRestricted
        case .authorizedWhenInUse, .authorizedAlways:
            .paused
        @unknown default:
            .locationUnavailable
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    /// Receives authorization changes and forwards them to the main-actor service state.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange(status)
        }
    }

    /// Receives new GPS samples and forwards them for validation and route recording.
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            self?.receive(locations)
        }
    }

    /// Receives Core Location failures and forwards their details for state handling.
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let message = error.localizedDescription
        let code = (error as? CLError)?.code

        Task { @MainActor [weak self] in
            self?.handleLocationFailure(code: code, message: message)
        }
    }
}
