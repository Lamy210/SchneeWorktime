/// A local review hint only. Neither a legal judgement nor an attendance mutation.
public enum BreakRecordAdvisory: Sendable, Equatable {
    case none, review, possibleReview

    public static func assess(snapshot: TimelineSnapshot, profile: WorkdayProfile) -> Self {
        let rest = snapshot.recordedRest
        if rest < reviewThreshold(worked: snapshot.bounds.lower, profile: profile) {
            return .review
        }
        if rest < reviewThreshold(worked: snapshot.bounds.upper, profile: profile) {
            return .possibleReview
        }
        return .none
    }

    /// Review thresholds are advisory, independent of the forecast-only remaining-rest override.
    private static func reviewThreshold(worked: Int64, profile: WorkdayProfile) -> Int64 {
        let durationHint: Int64 = if worked > 28800 {
            3600
        } else if worked > 21600 {
            2700
        } else {
            0
        }
        let profileHint = worked >= profile.target ? profile.expectedRest : 0
        return max(durationHint, profileHint)
    }
}
