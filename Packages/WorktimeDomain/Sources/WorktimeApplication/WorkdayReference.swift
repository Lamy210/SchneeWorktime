import WorktimeDomain

public extension WorkdayProfile {
    func capturingReference(at instant: Int64, timeZoneID: String, wallTime: ReferenceWallTime?) throws -> Self {
        let reference = try CapturedReference(startedAt: instant, timeZoneID: timeZoneID, wallTime: wallTime)
        return try Self(target: target, expectedRest: expectedRest, reference: reference)
    }
}

public extension WorktimeGlance {
    /// Nil includes legacy days and unavailable/disabled reference times.
    func referenceDifference() throws -> Int64? {
        let instant = day.state == .ended ? day.intervals.last?.end ?? observedAt : observedAt
        return try day.profile.reference?.difference(at: instant)
    }
}
