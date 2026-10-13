enum GPSReliability: Equatable {
    /// GPS is gathering enough recent good fixes to establish confidence.
    case acquiring

    /// GPS has produced the required sequence of accurate, plausible fixes.
    case reliable

    /// GPS has produced repeated bad fixes, an error, or no recent good fix.
    case unreliable
}
