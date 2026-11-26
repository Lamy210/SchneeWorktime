import WorktimeDomain

public enum JournalV2ClockBoundaryIntent: Sendable, Equatable {
    case clockIn(old: Int64, new: Int64, summary: ClockInSummarySelection)
    case clockOut(old: Int64, new: Int64)
}

public struct JournalV2ConfirmedClockBoundary {
    public let intent: JournalV2ClockBoundaryIntent
    public let correction: JournalV2WorktimeCorrectionProposal
    let context: JournalV2WorkActionContext
    let historical: HistoricalReviewContext?
}

public extension JournalV2WorktimeController {
    func previewConfirmedClockBoundary(
        _ intent: JournalV2ClockBoundaryIntent, day: Workday,
        historical: HistoricalReviewContext? = nil,
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> JournalV2ConfirmedClockBoundary {
        guard expected == workActionContext, expected.canAppend, day.state == .ended else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        let correction: JournalV2WorktimeCorrectionProposal
        switch intent {
        case let .clockIn(old, new, summary):
            correction = try previewClockInCorrection(
                expectedDay: day, oldStart: old, newStart: new, summary: summary,
                historical: historical, sample: sample
            )
        case let .clockOut(old, new):
            correction = try previewClockOutCorrection(
                expectedDay: day, oldEnd: old, newEnd: new, historical: historical, sample: sample
            )
        }
        return JournalV2ConfirmedClockBoundary(
            intent: intent, correction: correction, context: expected, historical: historical
        )
    }

    func isCurrent(_ proposal: JournalV2ConfirmedClockBoundary) -> Bool {
        workActionContext.canAppend &&
            workActionContext.permitsRoutineObservation(since: proposal.context) &&
            isCurrent(proposal.correction)
    }

    /// Recompute the identical intent and all displayed ended-day/summary
    /// effects. The fresh proposal still uses the complete repository CAS.
    mutating func commitConfirmedClockBoundary(
        _ proposal: JournalV2ConfirmedClockBoundary, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard isCurrent(proposal), sample.wall >= proposal.correction.before.observedAt else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        let fresh = try previewConfirmedClockBoundary(
            proposal.intent, day: proposal.correction.before.day, historical: proposal.historical,
            matching: workActionContext, sample: sample
        )
        guard Self.sameClockBoundaryGlance(proposal.correction.before, fresh.correction.before),
              Self.sameClockBoundaryGlance(proposal.correction.after, fresh.correction.after),
              proposal.correction.summaryImpacts == fresh.correction.summaryImpacts
        else { throw JournalV2WorktimeCorrectionError.staleProposal }
        return try commitCorrection(fresh.correction, sample: sample)
    }

    private static func sameClockBoundaryGlance(_ original: WorktimeGlance, _ fresh: WorktimeGlance) -> Bool {
        original.day.state == .ended && original.day == fresh.day &&
            original.snapshot == fresh.snapshot && original.reviewableGaps == fresh.reviewableGaps &&
            original.forecast.remaining == fresh.forecast.remaining &&
            original.forecast.surplus == fresh.forecast.surplus &&
            original.desiredDepartureAt == fresh.desiredDepartureAt
    }
}
