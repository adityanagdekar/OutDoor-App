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
        let state = Self.authorizationState(from: settings.authorizationStatus)
        OutDoorLog.reminder("NOTIFICATION_AUTHORIZATION_STATE state=\(state.logName)")
        return state
    }

    /// Requests ordinary alert and sound permission from foreground UI.
    @discardableResult
    func requestAuthorization() async throws -> AuthorizationState {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            let state = await authorizationState()
            OutDoorLog.reminder(
                "NOTIFICATION_AUTHORIZATION_REQUEST_COMPLETED granted=\(granted) state=\(state.logName)"
            )
            return state
        } catch {
            OutDoorLog.error("AllowanceReminder", "NOTIFICATION_AUTHORIZATION_REQUEST_FAILED error=\(error.localizedDescription)")
            throw error
        }
    }

    /// Schedules one nonrepeating reminder for the end of the session's original quota.
    @discardableResult
    func scheduleReminder(for session: InstagramSession, now: Date = Date()) async throws -> Bool {
        let state = await authorizationState()
        guard state == .authorized || state == .provisional else {
            OutDoorLog.reminder(
                "REMINDER_NOT_SCHEDULED id=\(session.id.uuidString) reason=authorization_\(state.logName)"
            )
            return false
        }

        let deliveryDate = session.startTimestamp.addingTimeInterval(
            max(0, session.quotaAtStartSeconds)
        )
        let delay = deliveryDate.timeIntervalSince(now)

        guard delay > 0 else {
            OutDoorLog.reminder(
                "REMINDER_NOT_SCHEDULED id=\(session.id.uuidString) reason=nonpositive_delay delaySeconds=\(delay)"
            )
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

        do {
            try await notificationCenter.add(request)
            let pendingRequests = await notificationCenter.pendingNotificationRequests()
            let isPending = pendingRequests.contains { $0.identifier == identifier }
            OutDoorLog.reminder(
                "REMINDER_SCHEDULED id=\(session.id.uuidString) delaySeconds=\(delay) verifiedPending=\(isPending)"
            )
            return isPending
        } catch {
            OutDoorLog.error(
                "AllowanceReminder",
                "REMINDER_SCHEDULE_FAILED id=\(session.id.uuidString) error=\(error.localizedDescription)"
            )
            throw error
        }
    }

    /// Cancels every pending allowance reminder created by OutDoor.
    func cancelAllAllowanceReminders() async {
        let requests = await notificationCenter.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }

        guard !identifiers.isEmpty else {
            OutDoorLog.reminder("REMINDER_CANCEL_ALL count=0")
            return
        }

        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: identifiers
        )
        OutDoorLog.reminder("REMINDER_CANCEL_ALL count=\(identifiers.count)")
    }

    /// Cancels the pending reminder for a session that ended before delivery.
    func cancelReminder(for sessionID: UUID) {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [Self.notificationIdentifier(for: sessionID)]
        )
        OutDoorLog.reminder("REMINDER_CANCELLED id=\(sessionID.uuidString)")
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

private extension AllowanceReminderService.AuthorizationState {
    nonisolated var logName: String {
        switch self {
        case .unknown:
            "unknown"
        case .notRequested:
            "notRequested"
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        case .provisional:
            "provisional"
        }
    }
}
