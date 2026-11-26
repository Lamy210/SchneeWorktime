import WorktimeDomain

/// A confirmation must refer to the exact Journal and checkpoint generation
/// currently owned by the schema-2 controller, not just the day/revision.
public extension JournalV2WorktimeController {
    func previewConfirmedReview(
        source: ObservationGap, selection: ObservationGap,
        classification: ReviewClassification,
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> JournalV2WorktimeCorrectionProposal {
        guard expected == workActionContext, let day = expected.day else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        guard expected.canAppend else {
            throw JournalV2WorkActionError.insufficientCapacity
        }
        return try previewReview(
            expectedDay: day, source: source, selection: selection,
            classification: classification, sample: sample
        )
    }

    mutating func commitConfirmedReview(
        _ proposal: JournalV2WorktimeCorrectionProposal,
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard expected == workActionContext,
              proposal.kind == .observationReview,
              proposal.before.day == expected.day, isCurrent(proposal)
        else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        guard expected.canAppend else {
            throw JournalV2WorkActionError.insufficientCapacity
        }
        return try commitCorrection(proposal, sample: sample)
    }
}
