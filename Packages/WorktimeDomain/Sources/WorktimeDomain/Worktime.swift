public enum WorktimeError: Error, Equatable {
    case invalidInterval, overlappingIntervals, invalidDuration, overflow
}

public struct WorkSpan: Sendable, Equatable {
    public let start: Int64
    public let end: Int64
    public let verified: Bool

    public init(start: Int64, end: Int64, verified: Bool) {
        self.start = start
        self.end = end
        self.verified = verified
    }
}

public enum Attainment: Sendable, Equatable {
    case notReached, possible, reached
}

public enum Crossing: Sendable, Equatable {
    case unavailable, exact(Int64), range(ClosedRange<Int64>)
}

public struct WorkBounds: Sendable, Equatable {
    public let lower: Int64
    public let upper: Int64
    public let attainment: Attainment
    public let crossing: Crossing
}

public enum PreviewState: Sendable, Equatable {
    case working, onBreak(returnAt: Int64?), ended
}

public enum DeparturePreview: Sendable, Equatable {
    case feasible(worked: ClosedRange<Int64>, futureRest: Int64)
    case infeasible, unknown, invalidCandidate, ended
}

public enum Worktime {
    private static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw WorktimeError.overflow }
        return value
    }

    private static func difference(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        guard !overflow else { throw WorktimeError.overflow }
        return value
    }

    public static func bounds(spans: [WorkSpan], now: Int64, target: Int64) throws -> WorkBounds {
        guard target > 0 else { throw WorktimeError.invalidDuration }
        var lower: Int64 = 0
        var upper: Int64 = 0
        var earliest: Int64?
        var latest: Int64?
        var previousEnd: Int64?
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start < span.end, span.end <= now else { throw WorktimeError.invalidInterval }
            if let previousEnd, span.start < previousEnd { throw WorktimeError.overlappingIntervals }
            previousEnd = span.end
            let length = try difference(span.end, span.start)
            let newUpper = try add(upper, length)
            if earliest == nil, newUpper >= target {
                earliest = try add(span.start, target - upper)
            }
            upper = newUpper
            if span.verified {
                let newLower = try add(lower, length)
                if latest == nil, newLower >= target {
                    latest = try add(span.start, target - lower)
                }
                lower = newLower
            }
        }
        let attainment: Attainment = lower >= target ? .reached : upper >= target ? .possible : .notReached
        let crossing: Crossing
        if let earliest, let latest {
            crossing = earliest == latest ? .exact(earliest) : .range(earliest...latest)
        } else {
            crossing = .unavailable
        }
        return WorkBounds(lower: lower, upper: upper, attainment: attainment, crossing: crossing)
    }

    public static func preview(
        bounds: WorkBounds, now: Int64, candidate: Int64, remainingRest: Int64, state: PreviewState
    ) throws -> DeparturePreview {
        guard remainingRest >= 0 else { throw WorktimeError.invalidDuration }
        guard state != .ended else { return .ended }
        guard candidate >= now else { return .invalidCandidate }
        if candidate == now {
            return .feasible(worked: bounds.lower...bounds.upper, futureRest: 0)
        }
        let window = try difference(candidate, now)
        let requiredRest: Int64
        switch state {
        case .working:
            requiredRest = remainingRest
        case let .onBreak(returnAt):
            guard let returnAt else { return .unknown }
            guard returnAt >= now, returnAt <= candidate else { return .infeasible }
            requiredRest = max(remainingRest, try difference(returnAt, now))
        case .ended:
            return .ended
        }
        guard requiredRest <= window else { return .infeasible }
        let futureWork = window - requiredRest
        return try .feasible(
            worked: add(bounds.lower, futureWork)...add(bounds.upper, futureWork), futureRest: requiredRest
        )
    }
}
