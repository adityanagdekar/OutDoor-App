import Foundation

/// Persists the wall-clock Instagram access window used by both the app and App Intent.
enum InstagramAccessStore {
    nonisolated static let expirationKey = "instagramAccessExpiresAt"

    private static var defaults: UserDefaults {
        .standard
    }

    /// Returns the stored expiration date when its persisted timestamp is valid.
    static var expirationDate: Date? {
        guard let storedValue = defaults.object(forKey: expirationKey) else {
            return nil
        }

        let timestamp: TimeInterval
        if let number = storedValue as? NSNumber {
            timestamp = number.doubleValue
        } else if let date = storedValue as? Date {
            timestamp = date.timeIntervalSince1970
        } else {
            return nil
        }

        guard timestamp.isFinite, timestamp > 0 else {
            return nil
        }

        return Date(timeIntervalSince1970: timestamp)
    }

    /// Reports whether the persisted access window is still active at the supplied time.
    static func hasActiveAccess(at date: Date = Date()) -> Bool {
        guard let expirationDate else {
            return false
        }

        return expirationDate > date
    }

    /// Starts a new wall-clock access window and persists its expiration timestamp.
    @discardableResult
    static func grantAccess(for duration: TimeInterval, from date: Date = Date()) -> Date? {
        guard duration.isFinite, duration > 0 else {
            clearAccess()
            return nil
        }

        let expirationDate = date.addingTimeInterval(duration)
        defaults.set(expirationDate.timeIntervalSince1970, forKey: expirationKey)
        return expirationDate
    }

    /// Removes any active or expired access window from persistent storage.
    static func clearAccess() {
        defaults.removeObject(forKey: expirationKey)
    }
}
