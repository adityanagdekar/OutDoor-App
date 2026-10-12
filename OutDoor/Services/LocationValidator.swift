import CoreLocation
import Foundation

struct LocationValidator {
    /// The worst horizontal accuracy accepted for a route point, in meters.
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 30

    /// The oldest accepted location sample, in seconds.
    static let maximumLocationAge: TimeInterval = 10

    /// The highest plausible walking speed, in meters per second.
    static let maximumWalkingSpeed: CLLocationSpeed = 12

    /// The minimum movement recorded as a route segment, in meters.
    static let minimumMovementDistance: CLLocationDistance = 2.5

    /// Validates a GPS sample and returns its accepted distance from the previous route point.
    static func acceptedSegmentDistance(
        for candidate: CLLocation,
        after previousLocation: CLLocation?,
        now: Date = Date()
    ) -> CLLocationDistance? {
        guard candidate.horizontalAccuracy >= 0,
              candidate.horizontalAccuracy <= maximumHorizontalAccuracy else {
            return nil
        }

        let locationAge = now.timeIntervalSince(candidate.timestamp)
        guard locationAge >= 0, locationAge <= maximumLocationAge else {
            return nil
        }

        guard let previousLocation else {
            return 0
        }

        let elapsedTime = candidate.timestamp.timeIntervalSince(previousLocation.timestamp)
        guard elapsedTime.isFinite, elapsedTime > 0 else {
            return nil
        }

        let segmentDistance = candidate.distance(from: previousLocation)
        guard segmentDistance.isFinite,
              segmentDistance >= minimumMovementDistance else {
            return nil
        }

        let impliedSpeed = segmentDistance / elapsedTime
        guard impliedSpeed.isFinite,
              impliedSpeed <= maximumWalkingSpeed else {
            return nil
        }

        return segmentDistance
    }
}
