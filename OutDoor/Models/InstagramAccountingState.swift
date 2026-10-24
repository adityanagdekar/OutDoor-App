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

/// A persisted verified-walking reward that also contributes Instagram credit.
nonisolated struct WalkingCreditEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let outdoorSessionID: UUID?
    let earnedAt: Date
    let durationSeconds: TimeInterval

    init(
        id: UUID = UUID(),
        outdoorSessionID: UUID? = nil,
        earnedAt: Date,
        durationSeconds: TimeInterval
    ) {
        self.id = id
        self.outdoorSessionID = outdoorSessionID
        self.earnedAt = earnedAt
        self.durationSeconds = durationSeconds
    }
}

/// A read-only summary prepared for the Instagram insights UI.
nonisolated struct InstagramInsightsSnapshot: Equatable, Sendable {
    static let empty = InstagramInsightsSnapshot(
        availableCreditSeconds: 0,
        estimatedUsageTodaySeconds: 0,
        estimatedExcessTodaySeconds: 0,
        verifiedWalkingTodaySeconds: 0
    )

    let availableCreditSeconds: TimeInterval
    let estimatedUsageTodaySeconds: TimeInterval
    let estimatedExcessTodaySeconds: TimeInterval
    let verifiedWalkingTodaySeconds: TimeInterval
}

/// The result of attempting to begin or reuse an Instagram session.
nonisolated struct InstagramSessionStartResult: Sendable {
    let isAllowed: Bool
    let session: InstagramSession?
    let didCreateSession: Bool
    let remainingSeconds: TimeInterval
}

/// The complete locally persisted Instagram accounting document.
nonisolated struct InstagramAccountingState: Codable, Sendable {
    static let currentSchemaVersion = 1

    var availableCreditSeconds: TimeInterval
    var activeSession: InstagramSession?
    var completedSessions: [InstagramSession]
    var verifiedWalkingEntries: [WalkingCreditEntry]
    var schemaVersion: Int
    var hasCompletedLegacyExpirationMigration: Bool

    /// All persisted verified walking time, independent of Instagram usage.
    var totalVerifiedWalkingSeconds: TimeInterval {
        verifiedWalkingEntries.reduce(0) { total, entry in
            guard entry.durationSeconds.isFinite else {
                return total
            }

            return total + max(0, entry.durationSeconds)
        }
    }

    /// All finalized Instagram time estimated from Shortcuts events.
    var totalEstimatedInstagramUsageSeconds: TimeInterval {
        completedSessions.reduce(0) { total, session in
            guard session.status == .finalized,
                  let elapsed = session.elapsedSeconds,
                  elapsed.isFinite else {
                return total
            }

            return total + max(0, elapsed)
        }
    }

    /// Historical usage beyond allowance; this never reduces available credit.
    var totalExcessUsageSeconds: TimeInterval {
        completedSessions.reduce(0) { total, session in
            guard session.status == .finalized,
                  let excess = session.excessSeconds,
                  excess.isFinite else {
                return total
            }

            return total + max(0, excess)
        }
    }

    init(
        availableCreditSeconds: TimeInterval = 0,
        activeSession: InstagramSession? = nil,
        completedSessions: [InstagramSession] = [],
        verifiedWalkingEntries: [WalkingCreditEntry] = [],
        schemaVersion: Int = currentSchemaVersion,
        hasCompletedLegacyExpirationMigration: Bool = false
    ) {
        self.availableCreditSeconds = availableCreditSeconds
        self.activeSession = activeSession
        self.completedSessions = completedSessions
        self.verifiedWalkingEntries = verifiedWalkingEntries
        self.schemaVersion = schemaVersion
        self.hasCompletedLegacyExpirationMigration = hasCompletedLegacyExpirationMigration
    }

    private enum CodingKeys: String, CodingKey {
        case availableCreditSeconds
        case activeSession
        case completedSessions
        case verifiedWalkingEntries
        case schemaVersion
        case hasCompletedLegacyExpirationMigration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCreditSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .availableCreditSeconds
        ) ?? 0
        activeSession = try container.decodeIfPresent(
            InstagramSession.self,
            forKey: .activeSession
        )
        completedSessions = try container.decodeIfPresent(
            [InstagramSession].self,
            forKey: .completedSessions
        ) ?? []
        verifiedWalkingEntries = try container.decodeIfPresent(
            [WalkingCreditEntry].self,
            forKey: .verifiedWalkingEntries
        ) ?? []
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? Self.currentSchemaVersion
        hasCompletedLegacyExpirationMigration = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedLegacyExpirationMigration
        ) ?? false
    }
}
