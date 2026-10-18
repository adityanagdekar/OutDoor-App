import Foundation
import UserNotifications

/// Manages the single local allowance reminder associated with an Instagram session.
actor AllowanceReminderService {
    static let shared = AllowanceReminderService()

    nonisolated enum AuthorizationState: Equatable, Sendable {
        case unknown
        case notRequested
        case authorized
        case denied
        case provisional
    }

    private static let identifierPrefix = "instagram-allowance-"
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    /// Returns the current notification permission state without prompting.
    func authorizationState() async -> AuthorizationState {
        let settings = await notificationCenter.notificationSettings()
        return Self.authorizationState(from: settings.authorizationStatus)
    }

    /// Requests ordinary alert and sound permission from foreground UI.
    @discardableResult
    func requestAuthorization() async throws -> AuthorizationState {
        _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
        return await authorizationState()
    }

    /// Schedules one nonrepeating reminder for the end of the session's original quota.
    @discardableResult
    func scheduleReminder(for session: InstagramSession, now: Date = Date()) async throws -> Bool {
        let state = await authorizationState()
        guard state == .authorized || state == .provisional else {
            return false
        }

        let deliveryDate = session.startTimestamp.addingTimeInterval(
            max(0, session.quotaAtStartSeconds)
        )
        let delay = deliveryDate.timeIntervalSince(now)

        guard delay > 0 else {
            return false
        }

        let identifier = Self.notificationIdentifier(for: session.id)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Instagram Allowance Finished")
        content.body = String(
            localized: "Your Instagram allowance is finished. Time to take a break."
        )
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: delay,
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        try await notificationCenter.add(request)
        return true
    }

    /// Cancels the pending reminder for a session that ended before delivery.
    func cancelReminder(for sessionID: UUID) {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [Self.notificationIdentifier(for: sessionID)]
        )
    }

    /// Creates a stable notification identifier from the persisted session UUID.
    nonisolated static func notificationIdentifier(for sessionID: UUID) -> String {
        identifierPrefix + sessionID.uuidString
    }

    private nonisolated static func authorizationState(
        from status: UNAuthorizationStatus
    ) -> AuthorizationState {
        switch status {
        case .notDetermined:
            return .notRequested
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional, .ephemeral:
            return .provisional
        @unknown default:
            return .unknown
        }
    }
}
