import WorktimeDomain

public extension JournalV2WorktimeController {
    /// A normal local observation may advance while a person reads the proposal.
    /// The core still recomputes the assessment and compares its full result.
    mutating func commitConfirmedDesiredDeparture(
        _ proposal: JournalV2DesiredDepartureProposal,
        matching expected: JournalV2WorkActionContext,
        warningAcknowledged: Bool, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard workActionContext.permitsRoutineObservation(since: expected),
              expected.canAppend, isCurrent(proposal)
        else { throw DesiredDepartureSaveError.staleProposal }
        return try commitDesiredDeparture(
            proposal, warningAcknowledged: warningAcknowledged, sample: sample
        )
    }

    /// An explicit clear refers to the same committed intention, never a
    /// different Journal revision or a different live session.
    mutating func clearConfirmedDesiredDeparture(
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard workActionContext.permitsRoutineObservation(since: expected),
              expected.canAppend, let day = expected.day,
              session.catalog.desiredDepartures[day.id] != nil
        else { throw DesiredDepartureSaveError.staleProposal }
        return try clearDesiredDeparture(expectedDay: day, sample: sample)
    }
}
