import Foundation

/// Atomically saves and restores the latest recoverable outdoor-session snapshot.
nonisolated struct OutdoorSessionPersistenceStore {
    static let fileName = "ActiveOutdoorSession.json"

    enum StoreError: LocalizedError {
        case applicationSupportDirectoryUnavailable

        var errorDescription: String? {
            "OutDoor could not access its private Application Support directory."
        }
    }

    private let fileManager: FileManager
    private let customFileURL: URL?

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.customFileURL = fileURL
    }

    /// Returns the last saved session, or nil when no recoverable session exists.
    func load() throws -> OutdoorSessionSnapshot? {
        let fileURL = try snapshotFileURL()

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(OutdoorSessionSnapshot.self, from: data)
    }

    /// Atomically replaces the persisted active-session snapshot.
    func save(_ snapshot: OutdoorSessionSnapshot) throws {
        let fileURL = try snapshotFileURL()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Removes recovery state after the user explicitly ends the session.
    func clear() throws {
        let fileURL = try snapshotFileURL()

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        try fileManager.removeItem(at: fileURL)
    }

    private func snapshotFileURL() throws -> URL {
        if let customFileURL {
            return customFileURL
        }

        guard let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreError.applicationSupportDirectoryUnavailable
        }

        return directory.appendingPathComponent(Self.fileName)
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
