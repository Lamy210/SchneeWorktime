public enum GoalForecast: Sendable, Equatable {
    case projected(earliestGoalAt: Int64, estimatedDepartureAt: Int64)
    case reached, uncertain, onBreak, ended
}

public struct DailyForecast: Sendable, Equatable {
    public let remaining: ClosedRange<Int64>
    public let surplus: ClosedRange<Int64>
    public let goal: GoalForecast

    /// A read-only projection of already validated work bounds, never an attendance mutation.
    public static func calculate(
        worked: ClosedRange<Int64>, target: Int64, remainingRest: Int64,
        now: Int64, state: PreviewState
    ) throws -> DailyForecast {
        guard worked.lowerBound >= 0, target > 0, remainingRest >= 0 else {
            throw WorktimeError.invalidDuration
        }
        let remaining = max(0, target - worked.upperBound) ... max(0, target - worked.lowerBound)
        let surplus = max(0, worked.lowerBound - target) ... max(0, worked.upperBound - target)
        let goal: GoalForecast
        if state == .ended {
            goal = .ended
        } else if remaining.upperBound == 0 {
            goal = .reached
        } else if worked.lowerBound != worked.upperBound {
            goal = .uncertain
        } else if state == .working {
            let earliest = try add(now, remaining.upperBound)
            goal = try .projected(earliestGoalAt: earliest, estimatedDepartureAt: add(earliest, remainingRest))
        } else {
            goal = .onBreak
        }
        return DailyForecast(remaining: remaining, surplus: surplus, goal: goal)
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw WorktimeError.overflow }
        return sum
    }
}
