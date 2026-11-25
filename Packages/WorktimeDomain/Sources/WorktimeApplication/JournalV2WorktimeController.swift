import Foundation
import WorktimeDomain
import WorktimeStore

/// An opt-in schema-2 application core for verifying clock/Journal integration.
/// It is not wired into DesktopModel or the legacy WorktimeController.
/// The caller owns the exclusive session/directory lock and must discard this
/// value after any clock or storage error, especially an ambiguous COMMIT.
public struct JournalV2WorktimeController {
    private let repository: JournalV2Repository
    private var session: JournalV2Session
    private var clock: ClockObservation

    public var version: StoreVersion {
        session.version
    }

    public var checkpoint: ObservationCheckpoint? {
        session.checkpoint
    }

    public var journalCapacity: JournalCapacity {
        session.journalCapacity
    }

    /// Fresh schema-2 files only. An existing schema-1/unknown DB is never converted or erased.
    public init(url: URL, createIfMissing: Bool = false, sample: ClockSample) throws {
        repository = try JournalV2Repository(url: url, createIfMissing: createIfMissing)
        session = try repository.load(now: sample.wall)
        clock = ClockObservation(initial: sample)
        try recoverOpenInterval(sample: sample)
        try saveCheckpoint(sample: sample)
    }

    public mutating func refresh(sample: ClockSample) throws -> WorktimeGlance? {
        try observe(sample)
        try saveCheckpoint(sample: sample)
        return try glance(now: sample.wall)
    }

    /// Observation is recorded first; a command opening a work interval atomically
    /// carries its first checkpoint in the same Journal transaction.
    public mutating func perform(
        _ command: WorkdayCommand, sample: ClockSample
    ) throws -> WorktimeGlance? {
        try observe(sample)
        let observedAt: Int64? = switch command {
        case .clockIn, .endBreak, .resume: sample.wall
        case .startBreak, .clockOut: nil
        }
        session = try repository.apply(
            command, at: sample.wall, now: sample.wall,
            matching: session, observedAt: observedAt
        )
        try saveCheckpoint(sample: sample)
        return try glance(now: sample.wall)
    }

    /// Read-only exports are fenced by the complete Journal and observation checkpoint.
    public func writeBackup(to destination: URL, now: Int64) throws {
        try repository.writeBackup(to: destination, now: now, matching: session)
    }

    public func writeCSV(to destination: URL, now: Int64) throws {
        try repository.writeCSV(to: destination, now: now, matching: session)
    }

    /// Read-only deletion preview. The caller must own the session lock and
    /// stop owned reminders before invoking commitReset after explicit confirmation.
    public func previewReset(sample: ClockSample) throws -> JournalV2ResetPreview {
        var checked = clock
        _ = try checked.advance(to: sample)
        return try repository.previewReset(now: sample.wall, matching: session)
    }

    public func isCurrent(_ proposal: JournalV2ResetPreview) -> Bool {
        session.version == proposal.version
    }

    /// Logical Journal/Checkpoint deletion only, not physical erasure or external
    /// backup cleanup. A successful commit replaces this controller's cached
    /// state with the new epoch, so even accidental reuse cannot show old days.
    /// On any thrown error, the caller must discard and reopen this controller.
    public mutating func commitReset(_ proposal: JournalV2ResetPreview, sample: ClockSample) throws {
        guard isCurrent(proposal) else { throw SnapshotStoreError.staleVersion }
        var checked = clock
        _ = try checked.advance(to: sample)
        let cleared = try repository.commitReset(proposal, now: sample.wall)
        session = cleared
        clock = checked
    }

    /// A healthy same-epoch, earlier, fully ended Journal prefix is the only
    /// supported restoration source. Preview never changes the live database.
    public func previewRollback(file: URL, sample: ClockSample) throws -> JournalV2RollbackProposal {
        var checked = clock
        _ = try checked.advance(to: sample)
        return try repository.previewRollback(file: file, now: sample.wall, matching: session)
    }

    public func isCurrent(_ proposal: JournalV2RollbackProposal) -> Bool {
        session.version == proposal.currentVersion && session.catalog.activeID == nil
    }

    /// Requires settled notification cancellation, explicit user confirmation and
    /// an unused owner-private preservation destination outside the database tree.
    /// The repository durably preserves the exact current generation before SQL
    /// mutation. Never retry automatically after an uncertain outcome.
    public mutating func commitRollback(
        _ proposal: JournalV2RollbackProposal, preserveCurrentAt destination: URL, sample: ClockSample
    ) throws {
        guard isCurrent(proposal) else { throw SnapshotStoreError.staleVersion }
        var checked = clock
        _ = try checked.advance(to: sample)
        let restored = try repository.commitRollback(
            proposal, preserveCurrentAt: destination, now: sample.wall
        )
        session = restored
        clock = checked
    }

    /// Revalidates every committed event and the observation checkpoint before
    /// materializing a page; navigating history never writes attendance.
    public func recentHistory(
        now: Int64, offset: Int = 0, previous: WorktimeHistory? = nil
    ) throws -> WorktimeHistory {
        let stored = try repository.revalidate(session, now: now)
        if let previous {
            guard previous.version == stored.version else { throw WorktimeHistoryError.stalePage }
        } else if offset != 0 {
            throw WorktimeHistoryError.stalePage
        }
        return try WorktimeHistory(
            catalog: stored.catalog, version: stored.version, now: now, offset: offset
        )
    }

    public func isCurrent(_ history: WorktimeHistory) -> Bool {
        session.version == history.version
    }

    /// Only the committed catalog is read. Calendar navigation does not change
    /// the checkpoint, perform journal writes or schedule reminders.
    public func summary(
        period: WorktimeSummaryPeriod, sample: ClockSample, previous: WorktimeSummary? = nil
    ) throws -> WorktimeSummary {
        var checked = clock
        _ = try checked.advance(to: sample)
        let stored = try repository.revalidate(session, now: sample.wall)
        if let previous, previous.version != stored.version {
            throw WorktimeSummaryError.staleSummary
        }
        return try WorktimeSummary(
            catalog: stored.catalog, version: stored.version, period: period, now: sample.wall
        )
    }

    public func isCurrent(_ summary: WorktimeSummary) -> Bool {
        session.version == summary.version
    }

    /// Refuse stale display context and unobserved gaps. The event and fresh
    /// checkpoint are committed together when a working interval is active.
    /// A no-op request still revalidates the complete checkpoint CAS fence.
    public mutating func setFutureRest(
        minutes: Int?, expectedDay: Workday, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard session.catalog.days.last == expectedDay, session.catalog.activeID == expectedDay.id else {
            throw FutureRestChangeError.staleContext
        }
        if let minutes, !NextDaySettings.restRange.contains(minutes) {
            throw FutureRestChangeError.invalidMinutes
        }
        var checked = clock
        guard try checked.advance(to: sample) == nil else { throw FutureRestChangeError.staleContext }
        let seconds = minutes.map { Int64($0) * 60 }

        // Detect no-ops before requesting an atomic mutation+checkpoint. A no-op
        // carrying observedAt would otherwise be rejected by the Journal writer.
        var proposed = session.catalog
        try proposed.setFutureRest(
            dayID: expectedDay.id, remainingSeconds: seconds,
            now: sample.wall, expectedRevision: proposed.revision
        )
        if proposed == session.catalog {
            session = try repository.revalidate(session, now: sample.wall)
        } else {
            session = try repository.setFutureRest(
                dayID: expectedDay.id, remainingSeconds: seconds, now: sample.wall,
                matching: session, observedAt: activeWorkingDay == nil ? nil : sample.wall
            )
        }
        clock = checked
        try saveCheckpoint(sample: sample)
        return try glance(now: sample.wall)
    }

    /// A clock gap or clock regression cannot produce precise reminders. This
    /// reads only a CAS-verified committed generation; no notification is sent.
    public func reminderState(
        sample: ClockSample, departureLeads: Set<ReminderLead> = [.fifteen],
        earliestLeads: Set<ReminderLead> = [], referenceEnabled: Bool = false
    ) throws -> ReminderSyncState? {
        var checked = clock
        guard try checked.advance(to: sample) == nil else { return nil }
        let stored = try repository.revalidate(session, now: sample.wall)
        guard !stored.catalog.days.isEmpty else { return nil }
        let glance = try WorktimeGlance(catalog: stored.catalog, now: sample.wall)
        let basis = try glance.departureReminderBasis()
        let desired = ReminderPlan.desired(
            forecast: glance.forecast.goal, now: sample.wall, clockTrusted: true,
            departureLeads: departureLeads, earliestLeads: earliestLeads,
            referenceAt: referenceEnabled ? glance.day.profile.reference?.referenceAt : nil,
            departureBasis: basis
        )
        return ReminderSyncState(
            epoch: stored.version.epoch, dayID: glance.day.id,
            revision: stored.version.revision, desired: desired
        )
    }

    /// Exact displayed summary only. CSV is a report, never a restorable Journal.
    public func writeSummaryCSV(
        _ displayed: WorktimeSummary, to destination: URL, sample: ClockSample
    ) throws {
        let current = try summary(period: displayed.period, sample: sample, previous: displayed)
        guard current.daily == displayed.daily, current.worked == displayed.worked,
              current.target == displayed.target, current.recordedRest == displayed.recordedRest,
              current.endedDays == displayed.endedDays, current.uncertainDays == displayed.uncertainDays,
              current.dailyShortfall == displayed.dailyShortfall, current.dailySurplus == displayed.dailySurplus
        else { throw WorktimeSummaryError.staleSummary }
        try BackupFile.publish(WorktimeSummaryCSV.encode(displayed), to: destination)
    }

    private var activeWorkingDay: Workday? {
        guard let day = session.catalog.days.last, day.state == .working else { return nil }
        return day
    }

    /// After relaunch, time since the last verified observation is *uncertain*,
    /// not silently counted as worked. An absent checkpoint never proves work.
    private mutating func recoverOpenInterval(sample: ClockSample) throws {
        guard let day = activeWorkingDay, let start = day.intervals.last?.start else { return }
        let known = session.checkpoint?.observedAt
        if let known, known > sample.wall {
            throw ApplicationClockError.unreliableClock
        }
        let unknownStart = max(start, known ?? start)
        if unknownStart < sample.wall {
            session = try repository.recordObservation(
                dayID: day.id, gap: .init(start: unknownStart, end: sample.wall),
                now: sample.wall, matching: session, observedAt: sample.wall
            )
        }
    }

    private mutating func saveCheckpoint(sample: ClockSample) throws {
        guard let day = activeWorkingDay else { return }
        if let observed = session.checkpoint?.observedAt {
            guard observed <= sample.wall else { throw ApplicationClockError.unreliableClock }
            if sample.wall - observed < 10 {
                return
            }
        }
        session = try repository.saveObservationCheckpoint(
            dayID: day.id, observedAt: sample.wall, now: sample.wall, matching: session
        )
    }

    private mutating func observe(_ sample: ClockSample) throws {
        var nextClock = clock
        let gap = try nextClock.advance(to: sample)
        if let gap, let day = activeWorkingDay, let start = day.intervals.last?.start {
            let clipped = max(start, gap.start)
            if clipped < gap.end {
                session = try repository.recordObservation(
                    dayID: day.id, gap: .init(start: clipped, end: gap.end),
                    now: sample.wall, matching: session, observedAt: sample.wall
                )
            }
        }
        clock = nextClock
    }

    private func glance(now: Int64) throws -> WorktimeGlance? {
        guard !session.catalog.days.isEmpty else { return nil }
        return try WorktimeGlance(catalog: session.catalog, now: now)
    }
}

public enum JournalV2WorktimeCorrectionError: Error, Equatable {
    case staleProposal, invalidSelection
}

public enum JournalV2WorktimeCorrectionKind: Sendable {
    case observationReview, restStart, restEnd, clockIn, clockOut
}

/// A UI-consumable preview; changes to the displayed catalog are not persisted
/// until an explicit confirmation. The source includes a full Journal/checkpoint CAS.
public struct JournalV2WorktimeCorrectionProposal {
    public let version: StoreVersion
    public let kind: JournalV2WorktimeCorrectionKind
    public let before: WorktimeGlance
    public let after: WorktimeGlance
    public let summaryImpacts: [ClockInSummaryImpact]
    fileprivate let source: JournalV2WorktimeCorrectionSource

    public var movesSummaryPeriod: Bool {
        summaryImpacts.count > 1
    }
}

private enum JournalV2WorktimeCorrectionSource {
    case review(JournalV2ReviewProposal)
    case restStart(JournalV2RestCorrectionProposal)
    case restEnd(JournalV2RestCorrectionProposal)
    case clockIn(JournalV2ClockInCorrectionProposal)
    case clockOut(JournalV2ClockOutCorrectionProposal)
}

public extension JournalV2WorktimeController {
    /// Select a finished historical day from the displayed, versioned history.
    /// Nothing is written, and the current day remains unchanged.
    func historicalReviewContext(
        dayID: UUID, history: WorktimeHistory, sample: ClockSample
    ) throws -> HistoricalReviewContext {
        var checked = clock
        guard try checked.advance(to: sample) == nil else {
            throw HistoricalReviewError.staleContext
        }
        let stored = try repository.revalidate(session, now: sample.wall)
        guard stored.version == history.version,
              history.rows.contains(where: { $0.id == dayID }),
              stored.catalog.days.last?.id != dayID
        else { throw HistoricalReviewError.staleContext }
        let selected = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: dayID)
        guard selected.day.state == .ended else { throw HistoricalReviewError.staleContext }
        return HistoricalReviewContext(version: stored.version, glance: selected)
    }

    func isCurrent(_ context: HistoricalReviewContext) -> Bool {
        session.version == context.version && session.catalog.days.last?.id != context.glance.day.id &&
            session.catalog.days.contains(context.glance.day)
    }

    func previewReview(
        expectedDay: Workday, source: ObservationGap, selection: ObservationGap,
        classification: ReviewClassification,
        historical: HistoricalReviewContext? = nil, sample: ClockSample
    ) throws -> JournalV2WorktimeCorrectionProposal {
        let stored = try correctionSession(expectedDay: expectedDay, historical: historical, sample: sample)
        let before = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: expectedDay.id)
        guard before.reviewableGaps.contains(source),
              selection.start >= source.start, selection.end <= source.end, selection.start < selection.end
        else { throw JournalV2WorktimeCorrectionError.invalidSelection }
        let candidate = try repository.previewReview(
            dayID: expectedDay.id, selection: selection, classification: classification,
            now: sample.wall, matching: stored
        )
        var revised = stored.catalog
        try revised.commitReview(candidate.preview, now: sample.wall)
        return try correctionProposal(
            .review(candidate), before: before, revised: revised,
            kind: .observationReview, sample: sample
        )
    }

    func previewRestBoundaryCorrection(
        expectedDay: Workday, old: Int64, new: Int64, boundary: RestBoundary,
        historical: HistoricalReviewContext? = nil, sample: ClockSample
    ) throws -> JournalV2WorktimeCorrectionProposal {
        let stored = try correctionSession(expectedDay: expectedDay, historical: historical, sample: sample)
        let before = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: expectedDay.id)
        var revised = stored.catalog
        switch boundary {
        case .start:
            let candidate = try repository.previewRestStartCorrection(
                dayID: expectedDay.id, oldStart: old, newStart: new,
                now: sample.wall, matching: stored
            )
            try revised.commitRestStartCorrection(candidate.preview, now: sample.wall)
            return try correctionProposal(
                .restStart(candidate), before: before, revised: revised, kind: .restStart, sample: sample
            )
        case .end:
            let candidate = try repository.previewRestEndCorrection(
                dayID: expectedDay.id, oldEnd: old, newEnd: new,
                now: sample.wall, matching: stored
            )
            try revised.commitRestEndCorrection(candidate.preview, now: sample.wall)
            return try correctionProposal(
                .restEnd(candidate), before: before, revised: revised, kind: .restEnd, sample: sample
            )
        }
    }

    func previewClockOutCorrection(
        expectedDay: Workday, oldEnd: Int64, newEnd: Int64,
        historical: HistoricalReviewContext? = nil, sample: ClockSample
    ) throws -> JournalV2WorktimeCorrectionProposal {
        let stored = try correctionSession(expectedDay: expectedDay, historical: historical, sample: sample)
        let candidate = try repository.previewClockOutCorrection(
            dayID: expectedDay.id, oldEnd: oldEnd, newEnd: newEnd,
            now: sample.wall, matching: stored
        )
        var revised = stored.catalog
        try revised.commitClockOutCorrection(candidate.preview, now: sample.wall)
        let before = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: expectedDay.id)
        return try correctionProposal(
            .clockOut(candidate), before: before, revised: revised, kind: .clockOut, sample: sample
        )
    }

    func previewClockInCorrection(
        expectedDay: Workday, oldStart: Int64, newStart: Int64, summary: ClockInSummarySelection,
        historical: HistoricalReviewContext? = nil, sample: ClockSample
    ) throws -> JournalV2WorktimeCorrectionProposal {
        let stored = try correctionSession(expectedDay: expectedDay, historical: historical, sample: sample)
        let candidate = try repository.previewClockInCorrection(
            dayID: expectedDay.id, oldStart: oldStart, newStart: newStart,
            now: sample.wall, matching: stored
        )
        var revised = stored.catalog
        try revised.commitClockInCorrection(candidate.preview, now: sample.wall)
        let before = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: expectedDay.id)
        let impacts = try summary.impacts(
            candidate.preview, before: stored.catalog, after: revised,
            version: stored.version, now: sample.wall
        )
        return try correctionProposal(
            .clockIn(candidate), before: before, revised: revised,
            kind: .clockIn, sample: sample, impacts: impacts
        )
    }

    func isCurrent(_ proposal: JournalV2WorktimeCorrectionProposal) -> Bool {
        session.version == proposal.version && session.catalog.days.contains(proposal.before.day)
    }

    /// A correction to an ended historical day may coexist with an active day.
    /// Preserve that day's observedAt marker in the very same SQLite COMMIT
    /// as the audit event. Never manufacture a marker while on break.
    mutating func commitCorrection(
        _ proposal: JournalV2WorktimeCorrectionProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard isCurrent(proposal) else { throw JournalV2WorktimeCorrectionError.staleProposal }
        var checked = clock
        guard try checked.advance(to: sample) == nil else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        let stored = try repository.revalidate(session, now: sample.wall)
        guard stored.version == proposal.version, stored.catalog.days.contains(proposal.before.day) else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        let observedAt: Int64? = stored.catalog.days.last?.state == .working ? sample.wall : nil
        let updated = try commitVerifiedCorrection(
            proposal.source, now: sample.wall, observedAt: observedAt
        )
        session = updated
        clock = checked
        return try glance(now: sample.wall)
    }
}

private extension JournalV2WorktimeController {
    func commitVerifiedCorrection(
        _ candidate: JournalV2WorktimeCorrectionSource, now: Int64, observedAt: Int64?
    ) throws -> JournalV2Session {
        switch candidate {
        case let .review(plan):
            try repository.commitReview(plan, now: now, observedAt: observedAt)
        case let .restStart(plan):
            try repository.commitRestStartCorrection(plan, now: now, observedAt: observedAt)
        case let .restEnd(plan):
            try repository.commitRestEndCorrection(plan, now: now, observedAt: observedAt)
        case let .clockIn(plan):
            try repository.commitClockInCorrection(plan, now: now, observedAt: observedAt)
        case let .clockOut(plan):
            try repository.commitClockOutCorrection(plan, now: now, observedAt: observedAt)
        }
    }

    func correctionSession(
        expectedDay: Workday, historical: HistoricalReviewContext?, sample: ClockSample
    ) throws -> JournalV2Session {
        var checked = clock
        guard try checked.advance(to: sample) == nil else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        let stored = try repository.revalidate(session, now: sample.wall)
        if let historical {
            guard isCurrent(historical), historical.glance.day == expectedDay,
                  stored.catalog.days.contains(expectedDay)
            else { throw JournalV2WorktimeCorrectionError.staleProposal }
        } else if stored.catalog.days.last != expectedDay {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        return stored
    }

    func correctionProposal(
        _ source: JournalV2WorktimeCorrectionSource, before: WorktimeGlance,
        revised: WorkdayCatalog, kind: JournalV2WorktimeCorrectionKind, sample: ClockSample,
        impacts: [ClockInSummaryImpact] = []
    ) throws -> JournalV2WorktimeCorrectionProposal {
        let after = try WorktimeGlance(catalog: revised, now: sample.wall, dayID: before.day.id)
        return JournalV2WorktimeCorrectionProposal(
            version: session.version, kind: kind, before: before, after: after,
            summaryImpacts: impacts, source: source
        )
    }
}
