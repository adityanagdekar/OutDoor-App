enum DistanceSource: Equatable, Sendable {
    /// Core Location is currently contributing to the displayed distance.
    case gps

    /// Core Motion pedometer estimates are currently contributing to the displayed distance.
    case pedometer
}
