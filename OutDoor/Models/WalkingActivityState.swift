enum WalkingActivityState: String, Codable, Equatable, Sendable {
    /// The session is prepared but has not started.
    case ready

    /// Sensors are active while the app waits to verify walking movement.
    case acquiringMovement

    /// Walking is verified, so active time earns reward time.
    case walking

    /// No walking is verified, so active time is recorded as stationary.
    case stationary

    /// The session is preserved while sensors and timers are stopped.
    case paused

    /// The session has ended and its final measurements are retained.
    case completed
}
