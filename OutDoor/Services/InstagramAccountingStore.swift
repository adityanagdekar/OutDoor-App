import Foundation

/// Serializes access to the app's private Instagram accounting JSON document.
actor InstagramAccountingStore {
    static let shared = InstagramAccountingStore()

    static let fileName = "InstagramAccountingState.json"

    enum StoreError: LocalizedError {
        case applicationSupportDirectoryUnavailable
        case invalidCreditDuration

        var errorDescription: String? {
            switch self {
            case .applicationSupportDirectoryUnavailable:
                return "OutDoor could not access its private Application Support directory."
            case .invalidCreditDuration:
                return "Walking credit must be a positive, finite duration."
            }
        }
    }

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let customFileURL: URL?

    /// Uses a custom URL for tests, or OutDoor's Application Support directory in production.
    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        fileURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.customFileURL = fileURL
    }

    /// Loads the persisted state, or returns a new empty state when no file exists yet.
    func loadState() throws -> InstagramAccountingState {
        let fileURL = try accountingFileURL()
        var state: InstagramAccountingState

        if fileManager.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            state = try decoder.decode(InstagramAccountingState.self, from: data)
        } else {
            state = InstagramAccountingState()
        }

        if !state.hasCompletedLegacyExpirationMigration {
            userDefaults.removeObject(forKey: InstagramAccessStore.expirationKey)
            state.availableCreditSeconds = 0
            state.hasCompletedLegacyExpirationMigration = true
            try saveState(state)
        }

        return state
    }

    /// Atomically replaces the persisted accounting document with the supplied state.
    func saveState(_ state: InstagramAccountingState) throws {
        let fileURL = try accountingFileURL()
        try createParentDirectoryIfNeeded(for: fileURL)

        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Builds today's read-only insights using the user's current calendar day.
    func insights(
        at date: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> InstagramInsightsSnapshot {
        let state = try loadState()
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else {
            return .empty
        }

        var usageToday: TimeInterval = 0
        var excessToday: TimeInterval = 0

        for session in state.completedSessions where session.status == .finalized {
            let endTimestamp = session.endTimestamp ?? session.startTimestamp
            usageToday += overlapDuration(
                from: session.startTimestamp,
                to: endTimestamp,
                with: dayInterval
            )

            let excessStart = session.startTimestamp.addingTimeInterval(
                max(0, session.quotaAtStartSeconds)
            )
            excessToday += overlapDuration(
                from: excessStart,
                to: endTimestamp,
                with: dayInterval
            )
        }

        var effectiveAvailableCredit = state.availableCreditSeconds.isFinite
            ? max(0, state.availableCreditSeconds)
            : 0

        if let activeSession = state.activeSession {
            usageToday += overlapDuration(
                from: activeSession.startTimestamp,
                to: date,
                with: dayInterval
            )

            let quota = max(0, activeSession.quotaAtStartSeconds)
            let elapsed = max(0, date.timeIntervalSince(activeSession.startTimestamp))
            let provisionallyConsumed = min(elapsed, quota)
            effectiveAvailableCredit = max(
                0,
                effectiveAvailableCredit - provisionallyConsumed
            )

            let excessStart = activeSession.startTimestamp.addingTimeInterval(quota)
            excessToday += overlapDuration(
                from: excessStart,
                to: date,
                with: dayInterval
            )
        }

        return InstagramInsightsSnapshot(
            availableCreditSeconds: effectiveAvailableCredit,
            estimatedUsageTodaySeconds: usageToday,
            estimatedExcessTodaySeconds: excessToday
        )
    }

    /// Starts one session, or reuses the existing session without resetting its allowance.
    func startSession(at startTimestamp: Date = Date()) throws -> InstagramSessionStartResult {
        var state = try loadState()

        if let activeSession = state.activeSession {
            let elapsed = max(
                0,
                startTimestamp.timeIntervalSince(activeSession.startTimestamp)
            )
            let remaining = max(
                0,
                activeSession.quotaAtStartSeconds - elapsed
            )

            return InstagramSessionStartResult(
                isAllowed: remaining > 0,
                session: activeSession,
                didCreateSession: false,
                remainingSeconds: remaining
            )
        }

        let availableCredit = state.availableCreditSeconds.isFinite
            ? max(0, state.availableCreditSeconds)
            : 0

        guard availableCredit > 0 else {
            return InstagramSessionStartResult(
                isAllowed: false,
                session: nil,
                didCreateSession: false,
                remainingSeconds: 0
            )
        }

        let session = InstagramSession(
            startTimestamp: startTimestamp,
            quotaAtStartSeconds: availableCredit
        )
        state.activeSession = session
        try saveState(state)

        return InstagramSessionStartResult(
            isAllowed: true,
            session: session,
            didCreateSession: true,
            remainingSeconds: availableCredit
        )
    }

    /// Adds verified walking credit without changing an active session's original quota.
    @discardableResult
    func grantVerifiedWalkingCredit(
        seconds: TimeInterval,
        earnedAt: Date = Date()
    ) throws -> WalkingCreditEntry {
        guard seconds.isFinite, seconds > 0 else {
            throw StoreError.invalidCreditDuration
        }

        var state = try loadState()
        let entry = WalkingCreditEntry(
            earnedAt: earnedAt,
            durationSeconds: seconds
        )

        state.availableCreditSeconds = max(0, state.availableCreditSeconds) + seconds
        state.verifiedWalkingEntries.append(entry)

        try saveState(state)
        return entry
    }

    /// Finalizes the active Instagram session exactly once and deducts only covered usage.
    @discardableResult
    func endActiveSession(at endTimestamp: Date = Date()) throws -> InstagramSession? {
        var state = try loadState()

        guard var session = state.activeSession else {
            return nil
        }

        let elapsed = max(0, endTimestamp.timeIntervalSince(session.startTimestamp))
        let quotaAtStart = max(0, session.quotaAtStartSeconds)
        let consumed = min(elapsed, quotaAtStart)
        let excess = max(0, elapsed - quotaAtStart)

        session.endTimestamp = endTimestamp
        session.elapsedSeconds = elapsed
        session.consumedSeconds = consumed
        session.excessSeconds = excess
        session.status = .finalized

        state.availableCreditSeconds = max(
            0,
            state.availableCreditSeconds - consumed
        )
        state.activeSession = nil
        state.completedSessions.append(session)

        try saveState(state)
        return session
    }

    /// Deletes the accounting document and returns storage to its initial empty state.
    func deleteState() throws {
        let fileURL = try accountingFileURL()

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        try fileManager.removeItem(at: fileURL)
    }

    /// Returns the portion of a session interval that falls within a calendar day.
    private func overlapDuration(
        from start: Date,
        to end: Date,
        with dayInterval: DateInterval
    ) -> TimeInterval {
        guard end > start else {
            return 0
        }

        let overlapStart = max(start, dayInterval.start)
        let overlapEnd = min(end, dayInterval.end)
        return max(0, overlapEnd.timeIntervalSince(overlapStart))
    }

    /// Resolves the private Application Support file used by both the UI and App Intents.
    private func accountingFileURL() throws -> URL {
        if let customFileURL {
            return customFileURL
        }

        guard let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreError.applicationSupportDirectoryUnavailable
        }

        return applicationSupportDirectory.appendingPathComponent(Self.fileName)
    }

    /// Creates Application Support before the first atomic write.
    private func createParentDirectoryIfNeeded(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
