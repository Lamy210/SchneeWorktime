import Foundation
import WorktimeDomain

/// A selected ended day, its exact correction intent and the session that
/// supplied the displayed preview. This never authorizes a different day.
public struct JournalV2HistoricalGapProposal {
    public let correction: JournalV2WorktimeCorrectionProposal
    public let selection: ObservationGap
    public let classification: ReviewClassification
    let historical: HistoricalReviewContext
    let source: ObservationGap
    let displayed: JournalV2WorkActionContext
}

public extension JournalV2WorktimeController {
    func previewHistoricalGap(
        historical: HistoricalReviewContext, source: ObservationGap, selection: ObservationGap,
        classification: ReviewClassification, sample: ClockSample
    ) throws -> JournalV2HistoricalGapProposal {
        let displayed = workActionContext
        guard displayed.canAppend, isCurrent(historical) else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        let correction = try previewReview(
            expectedDay: historical.glance.day, source: source, selection: selection,
            classification: classification, historical: historical, sample: sample
        )
        return JournalV2HistoricalGapProposal(
            correction: correction, selection: selection, classification: classification,
            historical: historical, source: source, displayed: displayed
        )
    }

    func isCurrent(_ proposal: JournalV2HistoricalGapProposal) -> Bool {
        workActionContext.permitsRoutineObservation(since: proposal.displayed) &&
            isCurrent(proposal.historical) && workActionContext.canAppend
    }

    /// Ended-day totals do not advance with the active day's clock. Rebuild
    /// against the current owned session and require the same visible effect.
    /// The underlying correction still checks its complete Journal/checkpoint.
    mutating func commitHistoricalGap(
        _ proposal: JournalV2HistoricalGapProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard isCurrent(proposal) else { throw JournalV2WorktimeCorrectionError.staleProposal }
        let fresh = try previewHistoricalGap(
            historical: proposal.historical, source: proposal.source, selection: proposal.selection,
            classification: proposal.classification, sample: sample
        )
        guard Self.sameEndedGlance(proposal.correction.before, fresh.correction.before),
              Self.sameEndedGlance(proposal.correction.after, fresh.correction.after)
        else { throw JournalV2WorktimeCorrectionError.staleProposal }
        return try commitCorrection(fresh.correction, sample: sample)
    }

    private static func sameEndedGlance(_ original: WorktimeGlance, _ fresh: WorktimeGlance) -> Bool {
        original.day.state == .ended && original.day == fresh.day &&
            original.snapshot == fresh.snapshot && original.reviewableGaps == fresh.reviewableGaps &&
            original.desiredDepartureAt == fresh.desiredDepartureAt
    }
}
