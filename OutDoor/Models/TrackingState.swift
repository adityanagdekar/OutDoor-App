import Foundation

enum TrackingState: Equatable {
    /// The app has not asked the user for location access yet.
    case permissionNotRequested

    /// The user denied the app access to their location.
    case permissionDenied

    /// The system restricts location access, such as through parental controls.
    case permissionRestricted

    /// Location services cannot currently provide location updates.
    case locationUnavailable

    /// The session is active but is waiting for a sufficiently accurate GPS fix.
    case waitingForAccurateFix

    /// The session is actively receiving and recording location updates.
    case tracking

    /// The session is temporarily stopped and is not receiving location updates.
    case paused

    /// The session has ended and will not receive further location updates.
    case completed
}
