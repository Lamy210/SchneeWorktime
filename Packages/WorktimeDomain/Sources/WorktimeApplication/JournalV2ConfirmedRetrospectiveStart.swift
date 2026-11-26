import WorktimeDomain

public extension JournalV2WorktimeController {
    /// The displayed idle state and next-day settings must still match.
    /// Preview remains read-only; the repository owns full-state CAS.
    func previewConfirmedRetrospectiveStart(
        at instant: Int64, profile: WorkdayProfile,
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> RetrospectiveStartProposal {
        guard expected == workActionContext else {
            throw RetrospectiveStartError.staleProposal
        }
        // Keep future plans separate from attendance, using the same sampled
        // Instant that will be used for the underlying preview.
        guard instant <= sample.wall else { throw RetrospectiveStartError.futureStart }
        guard instant < sample.wall else { throw RetrospectiveStartError.currentStart }
        return try previewRetrospectiveStart(at: instant, profile: profile, sample: sample)
    }

    /// Never silently apply a proposal made with older target/rest settings.
    mutating func commitConfirmedRetrospectiveStart(
        _ proposal: RetrospectiveStartProposal, profile: WorkdayProfile,
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard expected == workActionContext, isCurrent(proposal),
              proposal.preview.day.profile == profile
        else { throw RetrospectiveStartError.staleProposal }
        return try commitRetrospectiveStart(proposal, sample: sample)
    }
}
