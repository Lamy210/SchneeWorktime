import Foundation

public enum RestEndCorrectionError: Error, Equatable {
    case invalidBoundary, overlapsUncertainty, changedPreview
}

public struct RestEndCorrectionPreview: Sendable, Equatable {
    public let dayID: UUID
    public let version: ReviewVersion
    public let oldEnd: Int64
    public let newEnd: Int64
    public let review: HistoryReviewResult
}

public extension WorkdayCatalog {
    /// Adjust only an existing contiguous rest -> work boundary. Never invent attendance across uncertainty.
    func previewRestEndCorrection(
        dayID: UUID, oldEnd: Int64, newEnd: Int64, now: Int64
    ) throws -> RestEndCorrectionPreview {
        guard let day = days.first(where: { $0.id == dayID }) else { throw CatalogReviewError.unknownDay }
        _ = try snapshot(dayID: dayID, now: now)
        let gaps = observations[dayID] ?? []
        let result = try RestEndCorrection.calculate(day: day, gaps: gaps, oldEnd: oldEnd, newEnd: newEnd, now: now)
        return RestEndCorrectionPreview(
            dayID: dayID, version: reviewVersion, oldEnd: oldEnd, newEnd: newEnd, review: result
        )
    }
}

enum RestEndCorrection {
    static func calculate(
        day: Workday, gaps: [ObservationGap], oldEnd: Int64, newEnd: Int64, now: Int64
    ) throws -> HistoryReviewResult {
        guard oldEnd != newEnd, newEnd < now,
              let index = day.intervals.firstIndex(where: { $0.kind == .rest && $0.end == oldEnd }),
              index + 1 < day.intervals.count
        else { throw RestEndCorrectionError.invalidBoundary }
        let rest = day.intervals[index]
        let work = day.intervals[index + 1]
        guard work.kind == .work, work.start == oldEnd,
              rest.start < newEnd, newEnd < (work.end ?? now)
        else { throw RestEndCorrectionError.invalidBoundary }
        let selection = ObservationGap(start: min(oldEnd, newEnd), end: max(oldEnd, newEnd))
        guard !gaps.contains(where: { $0.start < selection.end && selection.start < $0.end }) else {
            throw RestEndCorrectionError.overlapsUncertainty
        }
        var intervals = day.intervals
        intervals[index] = .init(start: rest.start, end: newEnd, kind: .rest)
        intervals[index + 1] = .init(start: newEnd, end: work.end, kind: .work)
        let updated = Workday(
            id: day.id, profile: day.profile, state: day.state, intervals: intervals,
            revision: day.revision, futureRestPlan: day.futureRestPlan
        )
        _ = try updated.snapshot(now: now, uncertainty: gaps)
        return HistoryReviewResult(
            selection: selection, classification: newEnd > oldEnd ? .rest : .work, reviewedAt: now,
            beforeIntervals: day.intervals, beforeUncertainty: gaps,
            afterIntervals: intervals, afterUncertainty: gaps
        )
    }
}
