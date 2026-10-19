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
    private(set) var mapLocation: CLLocation?
    private(set) var latestLocation: CLLocation?
    private(set) var horizontalAccuracy: CLLocationAccuracy?
    private(set) var locationError: LocationError?

    private let locationManager: CLLocationManager
    private var isSessionActive = false
    private var isRequestingMapLocation = false
    private var lastReliabilityFix: CLLocation?
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored var onGPSFixEvaluated: ((Bool, Date) -> Void)?
    @ObservationIgnored var onGPSFailure: (() -> Void)?

    /// Creates and configures the Core Location manager for continuous fitness tracking.
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
        // Session-level movement detection decides when tracking pauses. Allowing Core
        // Location to pause itself could prevent a When In Use session from restarting
        // until the app returns to the foreground.
        manager.pausesLocationUpdatesAutomatically = false
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

    /// Requests one foreground location fix for positioning the map without starting a session.
    func requestMapLocation() {
        guard !isSessionActive, CLLocationManager.locationServicesEnabled() else {
            return
        }

        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return
        }

        isRequestingMapLocation = true
        locationManager.requestLocation()
    }

    /// Starts a new session after clearing location data from the previous session.
    func startSession() {
        stopLocationUpdates()
        resetSession()
        isSessionActive = true
        beginTrackingIfPossible()
    }

    /// Pauses the active session and disables foreground and background location updates.
    func pauseSession() {
        guard isSessionActive else {
            return
        }

        stopLocationUpdates()
        lastReliabilityFix = nil
        trackingState = .paused
    }

    /// Restores session ownership without restarting sensors after process recovery.
    func restorePausedSession() {
        stopLocationUpdates()
        isSessionActive = true
        lastReliabilityFix = nil
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
            startLocationUpdates()
        @unknown default:
            stopLocationUpdates()
            trackingState = .locationUnavailable
        }
    }

    /// Updates service state and tracking behavior after location authorization changes.
    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        defer { onUpdate?() }
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

    /// Validates incoming locations and retains only the latest reliable position.
    private func receive(_ locations: [CLLocation]) {
        defer { onUpdate?() }
        let now = Date()

        if isRequestingMapLocation {
            receiveMapLocation(from: locations, now: now)
        }

        guard isSessionActive,
              trackingState == .waitingForAccurateFix || trackingState == .tracking else {
            return
        }

        for location in locations {
            horizontalAccuracy = location.horizontalAccuracy

            let isReliableFix = LocationValidator.isReliableFix(
                location,
                after: lastReliabilityFix,
                now: now
            )
            onGPSFixEvaluated?(isReliableFix, now)

            guard isReliableFix else {
                continue
            }

            lastReliabilityFix = location
            latestLocation = location
            mapLocation = location
            markLocationAvailable()
        }
    }

    /// Stores one accurate location for map positioning without affecting session distance.
    private func receiveMapLocation(from locations: [CLLocation], now: Date) {
        guard let location = locations.reversed().first(where: {
            if case .origin = LocationValidator.decision(for: $0, after: nil, now: now) {
                return true
            }

            return false
        }) else {
            return
        }

        mapLocation = location
        isRequestingMapLocation = false
    }

    /// Marks the service as actively tracking after accepting a location.
    private func markLocationAvailable() {
        trackingState = .tracking
        locationError = nil
    }

    /// Handles transient and terminal errors reported by Core Location.
    private func handleLocationFailure(
        code: CLError.Code?,
        message: String
    ) {
        defer { onUpdate?() }
        onGPSFailure?()
        isRequestingMapLocation = false

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

    /// Clears location, accuracy, and error data for a new session.
    private func resetSession() {
        latestLocation = nil
        lastReliabilityFix = nil
        horizontalAccuracy = nil
        locationError = nil
    }

    /// Enables continuous delivery for a session that starts or resumes in the foreground.
    private func startLocationUpdates() {
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
    }

    /// Stops the update stream and removes background-location eligibility.
    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
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

    /// Receives new GPS samples and forwards them for current-position validation.
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
