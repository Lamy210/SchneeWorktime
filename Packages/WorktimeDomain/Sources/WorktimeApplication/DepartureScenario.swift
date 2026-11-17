import WorktimeDomain

/// Defaults apply only when a new day is explicitly started.
public struct NextDaySettings: Sendable, Equatable {
    public static let targetRange = 5 ... 1440
    public static let restRange = 0 ... 1440
    public let profile: WorkdayProfile

    public init(targetMinutes: Int, restMinutes: Int) throws {
        guard Self.targetRange.contains(targetMinutes), Self.restRange.contains(restMinutes) else {
            throw WorkdayError.invalidProfile
        }
        profile = try WorkdayProfile(target: Int64(targetMinutes) * 60, expectedRest: Int64(restMinutes) * 60)
    }
}

public struct DepartureScenario: Sendable, Equatable {
    public let result: DeparturePreview
    public let observedAt: Int64
    public let candidate: Int64
    public let remaining: ClosedRange<Int64>?
    public let surplus: ClosedRange<Int64>?
}

public extension WorktimeGlance {
    /// Pure hypothetical calculation from the displayed snapshot; never updates attendance or saves a plan.
    func departureScenario(candidate: Int64, returnAt: Int64? = nil) throws -> DepartureScenario {
        let state: PreviewState = switch day.state {
        case .working: .working
        case .onBreak: .onBreak(returnAt: returnAt)
        case .ended: .ended
        }
        let result = try Worktime.preview(
            bounds: snapshot.bounds, now: observedAt, candidate: candidate,
            remainingRest: snapshot.remainingRest, state: state
        )
        guard case let .feasible(worked, _) = result else {
            return DepartureScenario(result: result, observedAt: observedAt, candidate: candidate,
                                     remaining: nil, surplus: nil)
        }
        let target = day.profile.target
        let remaining = max(0, target - worked.upperBound) ... max(0, target - worked.lowerBound)
        let surplus = max(0, worked.lowerBound - target) ... max(0, worked.upperBound - target)
        return DepartureScenario(result: result, observedAt: observedAt, candidate: candidate,
                                 remaining: remaining, surplus: surplus)
    }
}
