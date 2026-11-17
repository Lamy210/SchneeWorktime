import WorktimeDomain

public enum DesiredDepartureStatus: Sendable, Equatable {
    case feasible, uncertain, infeasible, expired, ended
}

/// A desired departure is an intention, not a clock-out or an automatic estimate.
public struct DesiredDepartureAssessment: Sendable, Equatable {
    public let scenario: DepartureScenario
    public let status: DesiredDepartureStatus

    public var requiresWarning: Bool {
        status == .infeasible || status == .uncertain
    }

    public func canSave(warningAcknowledged: Bool) -> Bool {
        switch status {
        case .feasible:
            true
        case .infeasible, .uncertain:
            warningAcknowledged
        case .expired, .ended:
            false
        }
    }

    /// Never fall back to the automatic estimate when an explicit intention is ineligible.
    public var notificationTarget: Int64? {
        status == .feasible ? scenario.candidate : nil
    }
}

public extension WorktimeGlance {
    /// Reassess against the latest committed snapshot. No hypothetical return time is persisted.
    func assessDesiredDeparture(at candidate: Int64) throws -> DesiredDepartureAssessment {
        let scenario = try departureScenario(candidate: candidate)
        let status: DesiredDepartureStatus
        if day.state == .ended {
            status = .ended
        } else if candidate <= observedAt {
            status = .expired
        } else {
            switch scenario.result {
            case let .feasible(worked, _):
                status = worked.lowerBound == worked.upperBound ? .feasible : .uncertain
            case .infeasible:
                status = .infeasible
            case .unknown:
                status = .uncertain
            case .invalidCandidate:
                status = .expired
            case .ended:
                status = .ended
            }
        }
        return DesiredDepartureAssessment(scenario: scenario, status: status)
    }
}
