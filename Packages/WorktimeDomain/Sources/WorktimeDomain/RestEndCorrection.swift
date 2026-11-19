import Foundation

public enum RestEndCorrectionError: Error, Equatable {
    case invalidBoundary, overlapsUncertainty, changedPreview
}

public enum RestBoundary: Sendable, Equatable {
    case start, end

    var leftKind: IntervalKind {
        self == .start ? .work : .rest
    }

    var rightKind: IntervalKind {
        self == .start ? .rest : .work
    }
}

public struct RestEndCorrectionPreview: Sendable, Equatable {
    public let dayID: UUID
    public let version: ReviewVersion
    public let oldEnd: Int64
    public let newEnd: Int64
    public let review: HistoryReviewResult
    public let boundary: RestBoundary
}

public extension WorkdayCatalog {
    /// Adjust only an existing contiguous rest -> work boundary. Never invent attendance across uncertainty.
    func previewRestEndCorrection(
        dayID: UUID, oldEnd: Int64, newEnd: Int64, now: Int64
    ) throws -> RestEndCorrectionPreview {
        try previewRestBoundaryCorrection(dayID: dayID, old: oldEnd, new: newEnd, boundary: .end, now: now)
    }

    /// Correct a recorded work -> rest boundary, including an ongoing break.
    func previewRestStartCorrection(
        dayID: UUID, oldStart: Int64, newStart: Int64, now: Int64
    ) throws -> RestEndCorrectionPreview {
        try previewRestBoundaryCorrection(dayID: dayID, old: oldStart, new: newStart, boundary: .start, now: now)
    }

    internal func previewRestBoundaryCorrection(
        dayID: UUID, old: Int64, new: Int64, boundary: RestBoundary, now: Int64
    ) throws -> RestEndCorrectionPreview {
        guard let day = days.first(where: { $0.id == dayID }) else { throw CatalogReviewError.unknownDay }
        _ = try snapshot(dayID: dayID, now: now)
        let gaps = observations[dayID] ?? []
        let result = try RestEndCorrection.calculate(
            day: day, gaps: gaps, oldEnd: old, newEnd: new, boundary: boundary, now: now
        )
        return RestEndCorrectionPreview(
            dayID: dayID, version: reviewVersion, oldEnd: old, newEnd: new, review: result, boundary: boundary
        )
    }
}

enum RestEndCorrection {
    static func calculate(
        day: Workday, gaps: [ObservationGap], oldEnd: Int64, newEnd: Int64, boundary: RestBoundary, now: Int64
    ) throws -> HistoryReviewResult {
        guard oldEnd != newEnd, newEnd < now,
              let index = day.intervals.firstIndex(where: { $0.kind == boundary.leftKind && $0.end == oldEnd }),
              index + 1 < day.intervals.count
        else { throw RestEndCorrectionError.invalidBoundary }
        let left = day.intervals[index]
        let right = day.intervals[index + 1]
        guard right.kind == boundary.rightKind, right.start == oldEnd,
              left.start < newEnd, newEnd < (right.end ?? now)
        else { throw RestEndCorrectionError.invalidBoundary }
        let selection = ObservationGap(start: min(oldEnd, newEnd), end: max(oldEnd, newEnd))
        guard !gaps.contains(where: { $0.start < selection.end && selection.start < $0.end }) else {
            throw RestEndCorrectionError.overlapsUncertainty
        }
        var intervals = day.intervals
        intervals[index] = .init(start: left.start, end: newEnd, kind: left.kind)
        intervals[index + 1] = .init(start: newEnd, end: right.end, kind: right.kind)
        let updated = Workday(
            id: day.id, profile: day.profile, state: day.state, intervals: intervals,
            revision: day.revision, futureRestPlan: day.futureRestPlan
        )
        _ = try updated.snapshot(now: now, uncertainty: gaps)
        let extendedKind = newEnd > oldEnd ? left.kind : right.kind
        return HistoryReviewResult(
            selection: selection, classification: extendedKind == .rest ? .rest : .work, reviewedAt: now,
            beforeIntervals: day.intervals, beforeUncertainty: gaps,
            afterIntervals: intervals, afterUncertainty: gaps
        )
    }
}
