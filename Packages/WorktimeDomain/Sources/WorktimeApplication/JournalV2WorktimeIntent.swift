import Foundation
import WorktimeDomain
import WorktimeStore

/// A schema-2 confirmation bound to the displayed committed epoch, not a reminder.
public struct JournalV2DesiredDepartureProposal: Sendable {
    let version: StoreVersion
    let dayID: UUID
    public let assessment: DesiredDepartureAssessment
}

public extension JournalV2WorktimeController {
    /// An explicit assertion that work began in the past. The past interval is
    /// asserted by the user, not inferred from an observation checkpoint.
    /// Preview does not mutate either the Journal or the in-memory clock.
    func previewRetrospectiveStart(
        at instant: Int64, profile: WorkdayProfile, sample: ClockSample
    ) throws -> RetrospectiveStartProposal {
        var checked = clock
        _ = try checked.advance(to: sample)
        let stored = try repository.revalidate(session, now: sample.wall)
        guard stored.journalCapacity.canOpenWorkday else {
            throw CatalogPersistenceError.insufficientStartCapacity
        }
        guard instant < sample.wall, stored.catalog.activeID == nil else {
            throw RetrospectiveStartError.invalidStart
        }
        var proposed = stored.catalog
        let command = WorkdayCommand.clockIn(id: UUID(), profile: profile)
        do {
            try proposed.apply(command, at: instant, now: sample.wall, expectedRevision: proposed.revision)
        } catch {
            throw RetrospectiveStartError.invalidStart
        }
        let preview = try WorktimeGlance(catalog: proposed, now: sample.wall)
        return RetrospectiveStartProposal(
            version: stored.version, command: command,
            startedAt: instant, preparedAt: sample.wall, preview: preview
        )
    }

    func isCurrent(_ proposal: RetrospectiveStartProposal) -> Bool {
        session.version == proposal.version && session.catalog.activeID == nil
    }

    /// Both the backdated event and its first actual observation are committed
    /// atomically. Any error or uncertain commit requires discarding the session.
    mutating func commitRetrospectiveStart(
        _ proposal: RetrospectiveStartProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard isCurrent(proposal), sample.wall >= proposal.preparedAt else {
            throw RetrospectiveStartError.staleProposal
        }
        var checked = clock
        guard try checked.advance(to: sample) == nil else {
            throw RetrospectiveStartError.staleProposal
        }
        session = try repository.apply(
            proposal.command, at: proposal.startedAt, now: sample.wall,
            matching: session, observedAt: sample.wall
        )
        clock = checked
        return try glance(now: sample.wall)
    }

    /// Read-only explicit departure-intention preview, not a clock-out.
    func previewDesiredDeparture(
        at candidate: Int64, sample: ClockSample
    ) throws -> JournalV2DesiredDepartureProposal {
        var checked = clock
        guard try checked.advance(to: sample) == nil else {
            throw DesiredDepartureSaveError.staleProposal
        }
        let stored = try repository.revalidate(session, now: sample.wall)
        guard stored.catalog.activeID != nil else {
            throw DesiredDepartureSaveError.staleProposal
        }
        let glance = try WorktimeGlance(catalog: stored.catalog, now: sample.wall)
        let assessment = try glance.assessDesiredDeparture(at: candidate)
        guard assessment.canSave(warningAcknowledged: true) else {
            throw DesiredDepartureSaveError.invalidCandidate
        }
        return JournalV2DesiredDepartureProposal(
            version: stored.version, dayID: glance.day.id, assessment: assessment
        )
    }

    func isCurrent(_ proposal: JournalV2DesiredDepartureProposal) -> Bool {
        session.version == proposal.version && session.catalog.activeID == proposal.dayID
    }

    /// Recompute the forecast against the current wall clock, then append a
    /// single intention event, atomically updating a working-day checkpoint.
    /// On break no working checkpoint is created.
    mutating func commitDesiredDeparture(
        _ proposal: JournalV2DesiredDepartureProposal,
        warningAcknowledged: Bool, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard isCurrent(proposal), sample.wall >= proposal.assessment.scenario.observedAt else {
            throw DesiredDepartureSaveError.staleProposal
        }
        let fresh = try previewDesiredDeparture(
            at: proposal.assessment.scenario.candidate, sample: sample
        )
        guard fresh.assessment.status == proposal.assessment.status,
              fresh.assessment.scenario.result == proposal.assessment.scenario.result
        else {
            throw DesiredDepartureSaveError.staleProposal
        }
        guard fresh.assessment.canSave(warningAcknowledged: warningAcknowledged) else {
            throw DesiredDepartureSaveError.confirmationRequired
        }
        var checked = clock
        guard try checked.advance(to: sample) == nil else {
            throw DesiredDepartureSaveError.staleProposal
        }
        let candidate = proposal.assessment.scenario.candidate
        if session.catalog.desiredDepartures[proposal.dayID] == candidate {
            session = try repository.revalidate(session, now: sample.wall)
        } else {
            session = try repository.setDesiredDeparture(
                dayID: proposal.dayID, candidate: candidate, warningAcknowledged: warningAcknowledged,
                now: sample.wall, matching: session,
                observedAt: session.catalog.days.last?.state == .working ? sample.wall : nil
            )
        }
        clock = checked
        try saveCheckpoint(sample: sample)
        return try glance(now: sample.wall)
    }

    /// A clear is also fenced by the displayed current day. Repeated clears are
    /// read-only and still verify a checkpoint-only concurrent write.
    mutating func clearDesiredDeparture(
        expectedDay: Workday, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard session.catalog.days.last == expectedDay, session.catalog.activeID == expectedDay.id else {
            throw DesiredDepartureSaveError.staleProposal
        }
        var checked = clock
        guard try checked.advance(to: sample) == nil else {
            throw DesiredDepartureSaveError.staleProposal
        }
        if session.catalog.desiredDepartures[expectedDay.id] == nil {
            session = try repository.revalidate(session, now: sample.wall)
        } else {
            session = try repository.setDesiredDeparture(
                dayID: expectedDay.id, candidate: nil, warningAcknowledged: false,
                now: sample.wall, matching: session,
                observedAt: expectedDay.state == .working ? sample.wall : nil
            )
        }
        clock = checked
        try saveCheckpoint(sample: sample)
        return try glance(now: sample.wall)
    }
}
