import Foundation

/// The lifecycle state of an estimated Instagram usage session.
nonisolated enum InstagramSessionStatus: String, Codable, Sendable {
    case active
    case finalized
    case requiresReview
    case discarded
}

/// A persisted Instagram session estimated from Shortcuts open and close events.
nonisolated struct InstagramSession: Codable, Identifiable, Sendable {
    let id: UUID
    let startTimestamp: Date
    let quotaAtStartSeconds: TimeInterval

    var endTimestamp: Date?
    var elapsedSeconds: TimeInterval?
    var consumedSeconds: TimeInterval?
    var excessSeconds: TimeInterval?
    var status: InstagramSessionStatus

    /// The unused portion of the session's original quota.
    var remainingSeconds: TimeInterval {
        max(0, quotaAtStartSeconds - (elapsedSeconds ?? 0))
    }

    init(
        id: UUID = UUID(),
        startTimestamp: Date,
        quotaAtStartSeconds: TimeInterval,
        endTimestamp: Date? = nil,
        elapsedSeconds: TimeInterval? = nil,
        consumedSeconds: TimeInterval? = nil,
        excessSeconds: TimeInterval? = nil,
        status: InstagramSessionStatus = .active
    ) {
        self.id = id
        self.startTimestamp = startTimestamp
        self.quotaAtStartSeconds = quotaAtStartSeconds
        self.endTimestamp = endTimestamp
        self.elapsedSeconds = elapsedSeconds
        self.consumedSeconds = consumedSeconds
        self.excessSeconds = excessSeconds
        self.status = status
    }
}

/// A future verified-walking credit entry. Creating entries is not connected yet.
nonisolated struct WalkingCreditEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let earnedAt: Date
    let durationSeconds: TimeInterval

    init(
        id: UUID = UUID(),
        earnedAt: Date,
        durationSeconds: TimeInterval
    ) {
        self.id = id
        self.earnedAt = earnedAt
        self.durationSeconds = durationSeconds
    }
}

/// The complete locally persisted Instagram accounting document.
nonisolated struct InstagramAccountingState: Codable, Sendable {
    static let currentSchemaVersion = 1

    var availableCreditSeconds: TimeInterval
    var activeSession: InstagramSession?
    var completedSessions: [InstagramSession]
    var verifiedWalkingEntries: [WalkingCreditEntry]
    var schemaVersion: Int

    init(
        availableCreditSeconds: TimeInterval = 0,
        activeSession: InstagramSession? = nil,
        completedSessions: [InstagramSession] = [],
        verifiedWalkingEntries: [WalkingCreditEntry] = [],
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.availableCreditSeconds = availableCreditSeconds
        self.activeSession = activeSession
        self.completedSessions = completedSessions
        self.verifiedWalkingEntries = verifiedWalkingEntries
        self.schemaVersion = schemaVersion
    }
}
