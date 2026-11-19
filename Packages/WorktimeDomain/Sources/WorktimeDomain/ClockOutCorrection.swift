import Foundation

public enum ClockOutCorrectionError: Error, Equatable {
    case invalidBoundary, overlapsNextDay, overlapsUncertainty, changedPreview
}

public struct ClockOutCorrectionPreview: Sendable, Equatable {
    public let dayID: UUID
    public let version: ReviewVersion
    public let oldEnd: Int64
    public let newEnd: Int64
    public let review: HistoryReviewResult
}

public extension WorkdayCatalog {
    /// Edit the final closed work interval of an ended day without shifting another day's records.
    func previewClockOutCorrection(
        dayID: UUID, oldEnd: Int64, newEnd: Int64, now: Int64
    ) throws -> ClockOutCorrectionPreview {
        guard let index = days.firstIndex(where: { $0.id == dayID }) else { throw CatalogReviewError.unknownDay }
        let day = days[index]
        guard day.state == .ended, let last = day.intervals.last, last.kind == .work,
              last.end == oldEnd, newEnd != oldEnd, last.start < newEnd, newEnd <= now
        else { throw ClockOutCorrectionError.invalidBoundary }
        if index + 1 < days.count,
           let nextStart = days[index + 1].intervals.first?.start, newEnd > nextStart
        {
            throw ClockOutCorrectionError.overlapsNextDay
        }
        _ = try snapshot(dayID: dayID, now: now)
        let selection = ObservationGap(start: min(oldEnd, newEnd), end: max(oldEnd, newEnd))
        let gaps = observations[dayID] ?? []
        guard !gaps.contains(where: { $0.start < selection.end && selection.start < $0.end }) else {
            throw ClockOutCorrectionError.overlapsUncertainty
        }
        var intervals = day.intervals
        intervals[intervals.count - 1] = .init(start: last.start, end: newEnd, kind: .work)
        let updated = Workday(
            id: day.id, profile: day.profile, state: day.state, intervals: intervals,
            revision: day.revision, futureRestPlan: day.futureRestPlan
        )
        _ = try updated.snapshot(now: now, uncertainty: gaps)
        let review = HistoryReviewResult(
            selection: selection, classification: newEnd > oldEnd ? .work : .gap, reviewedAt: now,
            beforeIntervals: day.intervals, beforeUncertainty: gaps,
            afterIntervals: intervals, afterUncertainty: gaps
        )
        return ClockOutCorrectionPreview(
            dayID: dayID, version: reviewVersion, oldEnd: oldEnd, newEnd: newEnd, review: review
        )
    }
}
