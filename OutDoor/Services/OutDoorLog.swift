import Foundation
import OSLog

/// Centralized, privacy-safe diagnostic checkpoints for Instagram accounting.
nonisolated enum OutDoorLog {
    private static let subsystem = "OutDoor"
    private static let accountingLogger = Logger(subsystem: subsystem, category: "InstagramAccounting")
    private static let intentLogger = Logger(subsystem: subsystem, category: "AppIntents")
    private static let reminderLogger = Logger(subsystem: subsystem, category: "AllowanceReminder")
    private static let insightsLogger = Logger(subsystem: subsystem, category: "Insights")
    private static let debugLogger = Logger(subsystem: subsystem, category: "DebugControls")

    /// Records persistent accounting reads, writes, grants, starts, and finalizations.
    static func accounting(_ message: String) {
        accountingLogger.notice("\(message, privacy: .public)")
    }

    /// Records App Intent entry, result, retry-safe reuse, and failures.
    static func intent(_ message: String) {
        intentLogger.notice("\(message, privacy: .public)")
    }

    /// Records notification permission, scheduling, verification, and cancellation.
    static func reminder(_ message: String) {
        reminderLogger.notice("\(message, privacy: .public)")
    }

    /// Records values loaded by the Insights UI.
    static func insights(_ message: String) {
        insightsLogger.notice("\(message, privacy: .public)")
    }

    /// Records explicit DEBUG credit and reset actions.
    static func debug(_ message: String) {
        debugLogger.notice("\(message, privacy: .public)")
    }

    /// Records failures at any checkpoint without swallowing the original error.
    static func error(_ category: String, _ message: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        logger.error("\(message, privacy: .public)")
    }
}
