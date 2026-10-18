import Foundation

/// Serializes access to the app's private Instagram accounting JSON document.
actor InstagramAccountingStore {
    static let shared = InstagramAccountingStore()

    static let fileName = "InstagramAccountingState.json"

    enum StoreError: LocalizedError {
        case applicationSupportDirectoryUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationSupportDirectoryUnavailable:
                return "OutDoor could not access its private Application Support directory."
            }
        }
    }

    private let fileManager: FileManager
    private let customFileURL: URL?

    /// Uses a custom URL for tests, or OutDoor's Application Support directory in production.
    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.customFileURL = fileURL
    }

    /// Loads the persisted state, or returns a new empty state when no file exists yet.
    func loadState() throws -> InstagramAccountingState {
        let fileURL = try accountingFileURL()

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return InstagramAccountingState()
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(InstagramAccountingState.self, from: data)
    }

    /// Atomically replaces the persisted accounting document with the supplied state.
    func saveState(_ state: InstagramAccountingState) throws {
        let fileURL = try accountingFileURL()
        try createParentDirectoryIfNeeded(for: fileURL)

        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
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
