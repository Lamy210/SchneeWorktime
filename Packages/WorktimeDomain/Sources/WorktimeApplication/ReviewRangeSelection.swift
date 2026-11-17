import WorktimeDomain

/// A bounded, nonempty subrange of a displayed reviewable gap, in integer seconds.
public enum ReviewRangeSelection {
    public static func duration(of gap: ObservationGap) -> Int64? {
        let (duration, overflow) = gap.end.subtractingReportingOverflow(gap.start)
        return !overflow && duration > 0 ? duration : nil
    }

    public static func selection(
        in gap: ObservationGap, startOffset: Int64, endOffset: Int64
    ) throws -> ObservationGap {
        guard let duration = duration(of: gap), startOffset >= 0,
              startOffset < endOffset, endOffset <= duration
        else { throw HistoryReviewError.invalidSelection }
        let (start, startOverflow) = gap.start.addingReportingOverflow(startOffset)
        let (end, endOverflow) = gap.start.addingReportingOverflow(endOffset)
        guard !startOverflow, !endOverflow else { throw HistoryReviewError.invalidSelection }
        return ObservationGap(start: start, end: end)
    }
}
