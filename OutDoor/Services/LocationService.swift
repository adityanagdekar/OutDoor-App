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
    private(set) var routeSegments: [RouteSegment] = []
    private(set) var gpsRouteDistance: CLLocationDistance = 0
    private(set) var horizontalAccuracy: CLLocationAccuracy?
    private(set) var locationError: LocationError?

    private let locationManager: CLLocationManager
    private var isSessionActive = false
    private var isRequestingMapLocation = false
    private var isRouteRecordingEnabled = true
    private var shouldReanchorAtNextReliableFix = false
    private var lastReliabilityFix: CLLocation?
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored var onGPSFixEvaluated: ((Bool, Date) -> Void)?
    @ObservationIgnored var onGPSFailure: (() -> Void)?

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

    /// Pauses the active session and stops location updates without clearing its route.
    func pauseSession() {
        guard isSessionActive else {
            return
        }

        stopLocationUpdates()
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

    /// Suspends GPS route and distance recording while fixes continue for reliability checks.
    func suspendRouteRecording() {
        isRouteRecordingEnabled = false
        shouldReanchorAtNextReliableFix = false
    }

    /// Resumes route recording by making the next reliable fix a zero-distance anchor.
    func resumeRouteRecordingAtNextReliableFix() {
        isRouteRecordingEnabled = true
        shouldReanchorAtNextReliableFix = true
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

    /// Validates incoming locations and records only accepted route points.
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

            if lastReliabilityFix == nil
                || location.timestamp > lastReliabilityFix?.timestamp ?? .distantPast {
                lastReliabilityFix = location
            }

            guard isRouteRecordingEnabled else {
                continue
            }

            if shouldReanchorAtNextReliableFix, isReliableFix {
                shouldReanchorAtNextReliableFix = false
                beginRouteSegment(at: location)
                continue
            }

            switch LocationValidator.decision(
                for: location,
                after: latestLocation,
                now: now
            ) {
            case .origin, .reanchor:
                beginRouteSegment(at: location)
            case .segment(let distance):
                gpsRouteDistance += distance
                latestLocation = location
                routeSegments[routeSegments.count - 1].coordinates.append(location.coordinate)
                markLocationAvailable()
            case .rejected:
                continue
            }
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

    /// Records a route anchor without adding distance from an earlier segment.
    private func beginRouteSegment(at location: CLLocation) {
        mapLocation = location
        latestLocation = location
        routeSegments.append(RouteSegment(coordinates: [location.coordinate]))
        markLocationAvailable()
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

    /// Clears all route, distance, accuracy, and error data for a new session.
    private func resetSession() {
        latestLocation = nil
        lastReliabilityFix = nil
        routeSegments = []
        gpsRouteDistance = 0
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
