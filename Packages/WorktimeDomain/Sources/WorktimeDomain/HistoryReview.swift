public enum ReviewClassification: Sendable, Equatable {
    case work, rest, gap
}

public enum HistoryReviewError: Error, Equatable {
    case invalidSelection, notUnverifiedWork
}

public struct HistoryReviewResult: Sendable, Equatable {
    public let selection: ObservationGap
    public let classification: ReviewClassification
    public let reviewedAt: Int64
    public let beforeIntervals: [RecordedInterval]
    public let beforeUncertainty: [ObservationGap]
    public let afterIntervals: [RecordedInterval]
    public let afterUncertainty: [ObservationGap]
}

/// Pure review calculation. Persist the result and its audit in one authorized store transaction.
public enum HistoryReview {
    public static func resolve(
        intervals: [RecordedInterval], uncertainty: [ObservationGap],
        selection: ObservationGap, classification: ReviewClassification, now: Int64
    ) throws -> HistoryReviewResult {
        guard selection.start < selection.end, selection.end <= now else {
            throw HistoryReviewError.invalidSelection
        }
        _ = try Timeline.snapshot(
            intervals: intervals, uncertainty: uncertainty, now: now, target: 1, expectedRest: 0
        )
        let ordered = intervals.sorted { $0.start < $1.start }
        guard let index = ordered.firstIndex(where: {
            $0.kind == .work && $0.start <= selection.start && ($0.end ?? now) >= selection.end
        }), covered(selection, by: uncertainty) else {
            throw HistoryReviewError.notUnverifiedWork
        }

        let revised: [RecordedInterval] = if classification == .work {
            intervals
        } else {
            replacing(ordered, at: index, selection: selection, classification: classification, now: now)
        }
        let remaining = uncertainty.flatMap { subtract(selection, from: $0) }
        _ = try Timeline.snapshot(
            intervals: revised, uncertainty: remaining, now: now, target: 1, expectedRest: 0
        )
        return HistoryReviewResult(
            selection: selection, classification: classification, reviewedAt: now,
            beforeIntervals: intervals, beforeUncertainty: uncertainty,
            afterIntervals: revised, afterUncertainty: remaining
        )
    }

    private static func covered(_ selection: ObservationGap, by gaps: [ObservationGap]) -> Bool {
        var cursor = selection.start
        for gap in gaps.sorted(by: { $0.start < $1.start }) where gap.end > cursor {
            if gap.start > cursor {
                return false
            }
            cursor = max(cursor, gap.end)
            if cursor >= selection.end {
                return true
            }
        }
        return false
    }

    private static func replacing(
        _ intervals: [RecordedInterval], at index: Int, selection: ObservationGap,
        classification: ReviewClassification, now: Int64
    ) -> [RecordedInterval] {
        let original = intervals[index]
        var replacement: [RecordedInterval] = []
        if original.start < selection.start {
            replacement.append(.init(start: original.start, end: selection.start, kind: .work))
        }
        let kind: IntervalKind = classification == .rest ? .rest : .gap
        replacement.append(.init(start: selection.start, end: selection.end, kind: kind))
        if original.end == nil || selection.end < (original.end ?? now) {
            replacement.append(.init(start: selection.end, end: original.end, kind: .work))
        }
        var copy = intervals
        copy.replaceSubrange(index ... index, with: replacement)
        return copy
    }

    private static func subtract(_ selection: ObservationGap, from gap: ObservationGap) -> [ObservationGap] {
        guard gap.start < selection.end, gap.end > selection.start else { return [gap] }
        var remaining: [ObservationGap] = []
        if gap.start < selection.start {
            remaining.append(.init(start: gap.start, end: selection.start))
        }
        if gap.end > selection.end {
            remaining.append(.init(start: selection.end, end: gap.end))
        }
        return remaining
    }
}
