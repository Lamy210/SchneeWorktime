public enum IntervalKind: Sendable, Equatable {
    case work, rest, gap
}

public struct RecordedInterval: Sendable, Equatable {
    public let start: Int64
    public let end: Int64?
    public let kind: IntervalKind

    public init(start: Int64, end: Int64?, kind: IntervalKind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

public struct ObservationGap: Sendable, Equatable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
}

public struct RestPlan: Sendable, Equatable {
    public let anchor: Int64
    public let remainingAtAnchor: Int64

    public init(anchor: Int64, remainingAtAnchor: Int64) {
        self.anchor = anchor
        self.remainingAtAnchor = remainingAtAnchor
    }
}

public struct TimelineSnapshot: Sendable, Equatable {
    public let bounds: WorkBounds
    public let recordedRest: Int64
    public let remainingRest: Int64
}

public enum Timeline {
    public static func snapshot(
        intervals: [RecordedInterval], uncertainty: [ObservationGap], now: Int64,
        target: Int64, expectedRest: Int64, override: RestPlan? = nil
    ) throws -> TimelineSnapshot {
        guard expectedRest >= 0 else { throw WorktimeError.invalidDuration }
        if let override, override.anchor > now || override.remainingAtAnchor < 0 {
            throw WorktimeError.invalidDuration
        }
        let ordered = try validated(intervals, now: now)
        let gaps = try merged(uncertainty, now: now)
        var spans: [WorkSpan] = []
        var recordedRest: Int64 = 0
        var consumedRest: Int64 = 0
        for interval in ordered {
            let end = interval.end ?? now
            guard interval.start < end else { continue }
            switch interval.kind {
            case .work:
                spans += splitWork(start: interval.start, end: end, gaps: gaps)
            case .rest:
                recordedRest = try addingDuration(recordedRest, start: interval.start, end: end)
                if let override, end > override.anchor {
                    let start = max(interval.start, override.anchor)
                    consumedRest = try addingDuration(consumedRest, start: start, end: end)
                }
            case .gap:
                break
            }
        }
        let remaining = if let override {
            max(0, override.remainingAtAnchor - consumedRest)
        } else {
            max(0, expectedRest - recordedRest)
        }
        return try TimelineSnapshot(
            bounds: Worktime.bounds(spans: spans, now: now, target: target),
            recordedRest: recordedRest,
            remainingRest: remaining
        )
    }

    private static func validated(_ intervals: [RecordedInterval], now: Int64) throws -> [RecordedInterval] {
        let ordered = intervals.sorted { $0.start < $1.start }
        var previousEnd: Int64?
        for (index, interval) in ordered.enumerated() {
            guard interval.start <= now else { throw WorktimeError.invalidInterval }
            if let end = interval.end {
                guard interval.start < end, end <= now else { throw WorktimeError.invalidInterval }
            } else {
                guard index == ordered.count - 1, interval.kind != .gap else {
                    throw WorktimeError.invalidInterval
                }
            }
            if let previousEnd, interval.start < previousEnd {
                throw WorktimeError.overlappingIntervals
            }
            previousEnd = interval.end ?? now
        }
        return ordered
    }

    private static func merged(_ gaps: [ObservationGap], now: Int64) throws -> [ObservationGap] {
        var result: [ObservationGap] = []
        for gap in gaps.sorted(by: { $0.start < $1.start }) {
            guard gap.start < gap.end, gap.end <= now else { throw WorktimeError.invalidInterval }
            if let last = result.last, gap.start <= last.end {
                result.removeLast()
                result.append(ObservationGap(start: last.start, end: max(last.end, gap.end)))
            } else {
                result.append(gap)
            }
        }
        return result
    }

    private static func splitWork(start: Int64, end: Int64, gaps: [ObservationGap]) -> [WorkSpan] {
        var result: [WorkSpan] = []
        var cursor = start
        for gap in gaps where gap.start < end && gap.end > start {
            let lower = max(start, gap.start)
            let upper = min(end, gap.end)
            if cursor < lower {
                result.append(WorkSpan(start: cursor, end: lower, verified: true))
            }
            result.append(WorkSpan(start: lower, end: upper, verified: false))
            cursor = upper
        }
        if cursor < end {
            result.append(WorkSpan(start: cursor, end: end, verified: true))
        }
        return result
    }

    private static func addingDuration(_ total: Int64, start: Int64, end: Int64) throws -> Int64 {
        let (duration, spanOverflow) = end.subtractingReportingOverflow(start)
        guard !spanOverflow else { throw WorktimeError.overflow }
        let (updated, totalOverflow) = total.addingReportingOverflow(duration)
        guard !totalOverflow else { throw WorktimeError.overflow }
        return updated
    }
}
