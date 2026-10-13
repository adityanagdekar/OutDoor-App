import CoreLocation
import Foundation

struct LocationValidator {
    enum Decision {
        case origin
        case segment(distance: CLLocationDistance)
        case reanchor
        case rejected
    }

    /// The worst horizontal accuracy accepted for a route point, in meters.
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 30

    /// The oldest accepted location sample, in seconds.
    static let maximumLocationAge: TimeInterval = 10

    /// The longest interval allowed between connected route points.
    static let maximumSegmentInterval: TimeInterval = 30

    /// The longest expected gap between fixes used as evidence of healthy GPS.
    static let maximumRegularFixInterval: TimeInterval = 10

    /// The highest plausible walking speed, in meters per second.
    static let maximumWalkingSpeed: CLLocationSpeed = 12

    /// The absolute minimum movement recorded as a route segment, in meters.
    static let minimumMovementDistance: CLLocationDistance = 3

    /// Scales the combined accuracy radii to reject likely stationary GPS drift.
    static let accuracyNoiseMultiplier = 1.5

    /// Checks whether a fix is accurate, recent, forward-moving in time, and physically plausible.
    static func isReliableFix(
        _ candidate: CLLocation,
        after previousFix: CLLocation?,
        now: Date = Date()
    ) -> Bool {
        guard candidate.horizontalAccuracy >= 0,
              candidate.horizontalAccuracy <= maximumHorizontalAccuracy else {
            return false
        }

        let locationAge = now.timeIntervalSince(candidate.timestamp)
        guard locationAge >= 0, locationAge <= maximumLocationAge else {
            return false
        }

        guard let previousFix else {
            return true
        }

        let elapsedTime = candidate.timestamp.timeIntervalSince(previousFix.timestamp)
        guard elapsedTime.isFinite,
              elapsedTime > 0,
              elapsedTime <= maximumRegularFixInterval else {
            return false
        }

        let displacement = candidate.distance(from: previousFix)
        guard displacement.isFinite else {
            return false
        }

        let impliedSpeed = displacement / elapsedTime
        return impliedSpeed.isFinite && impliedSpeed <= maximumWalkingSpeed
    }

    /// Validates one GPS sample and decides how it affects the route.
    static func decision(
        for candidate: CLLocation,
        after previousLocation: CLLocation?,
        now: Date = Date()
    ) -> Decision {
        guard candidate.horizontalAccuracy >= 0,
              candidate.horizontalAccuracy <= maximumHorizontalAccuracy else {
            return .rejected
        }

        let locationAge = now.timeIntervalSince(candidate.timestamp)
        guard locationAge >= 0, locationAge <= maximumLocationAge else {
            return .rejected
        }

        guard let previousLocation else {
            return .origin
        }

        let elapsedTime = candidate.timestamp.timeIntervalSince(previousLocation.timestamp)
        guard elapsedTime.isFinite, elapsedTime > 0 else {
            return .rejected
        }

        // A fresh fix following a long gap starts a new route segment. It must not
        // measure the GPS drift that occurred while updates were stopped.
        guard elapsedTime <= maximumSegmentInterval else {
            return .reanchor
        }

        let segmentDistance = candidate.distance(from: previousLocation)
        guard segmentDistance.isFinite else {
            return .rejected
        }

        let accuracyNoiseDistance = (
            candidate.horizontalAccuracy + previousLocation.horizontalAccuracy
        ) * accuracyNoiseMultiplier
        let requiredMovement = max(minimumMovementDistance, accuracyNoiseDistance)

        guard segmentDistance >= requiredMovement else {
            return .rejected
        }

        let impliedSpeed = segmentDistance / elapsedTime
        guard impliedSpeed.isFinite,
              impliedSpeed <= maximumWalkingSpeed else {
            return .rejected
        }

        return .segment(distance: segmentDistance)
    }
}
