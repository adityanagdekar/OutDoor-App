import Foundation

/// A recoverable snapshot of an outdoor session saved independently of live sensors.
nonisolated struct OutdoorSessionSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    let sessionID: UUID
    let startTimestamp: Date
    let savedAt: Date
    let elapsedSessionTime: TimeInterval
    let verifiedWalkingTime: TimeInterval
    let stationaryTime: TimeInterval
    let lastMovementTimestamp: Date?
    let pedometerStepBaseline: Int
    let pedometerDistanceBaseline: Double
    let estimatedDistance: Double
    let activityState: WalkingActivityState
    let wasPaused: Bool
    let schemaVersion: Int

    init(
        sessionID: UUID,
        startTimestamp: Date,
        savedAt: Date,
        elapsedSessionTime: TimeInterval,
        verifiedWalkingTime: TimeInterval,
        stationaryTime: TimeInterval,
        lastMovementTimestamp: Date?,
        pedometerStepBaseline: Int,
        pedometerDistanceBaseline: Double,
        estimatedDistance: Double,
        activityState: WalkingActivityState,
        wasPaused: Bool,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.sessionID = sessionID
        self.startTimestamp = startTimestamp
        self.savedAt = savedAt
        self.elapsedSessionTime = elapsedSessionTime
        self.verifiedWalkingTime = verifiedWalkingTime
        self.stationaryTime = stationaryTime
        self.lastMovementTimestamp = lastMovementTimestamp
        self.pedometerStepBaseline = pedometerStepBaseline
        self.pedometerDistanceBaseline = pedometerDistanceBaseline
        self.estimatedDistance = estimatedDistance
        self.activityState = activityState
        self.wasPaused = wasPaused
        self.schemaVersion = schemaVersion
    }
}
