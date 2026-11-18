import Foundation
import WorktimeDomain
import WorktimeStore

public struct WorktimeGlance: Sendable {
    public let day: Workday
    public let snapshot: TimelineSnapshot
    public let forecast: DailyForecast
    public let reviewableGaps: [ObservationGap]
    public let observedAt: Int64
    public let desiredDepartureAt: Int64?

    public init(catalog: WorkdayCatalog, now: Int64, dayID: UUID? = nil) throws {
        let selected = if let dayID {
            catalog.days.first(where: { $0.id == dayID })
        } else {
            catalog.days.last
        }
        guard let day = selected else { throw WorkdayError.noActiveDay }
        let snapshot = try catalog.snapshot(dayID: day.id, now: now)
        let state: PreviewState = switch day.state {
        case .working: .working
        case .onBreak: .onBreak(returnAt: nil)
        case .ended: .ended
        }
        self.day = day
        desiredDepartureAt = catalog.desiredDepartures[day.id]
        observedAt = now
        self.snapshot = snapshot
        reviewableGaps = Self.reviewable(day: day, gaps: catalog.observations[day.id] ?? [], now: now)
        forecast = try DailyForecast.calculate(
            worked: snapshot.bounds.lower ... snapshot.bounds.upper,
            target: day.profile.target, remainingRest: snapshot.remainingRest, now: now, state: state
        )
    }

    private static func reviewable(day: Workday, gaps: [ObservationGap], now: Int64) -> [ObservationGap] {
        day.intervals.filter { $0.kind == .work }.flatMap { interval in
            gaps.compactMap { gap in
                let start = max(interval.start, gap.start)
                let end = min(interval.end ?? now, gap.end)
                return start < end ? ObservationGap(start: start, end: end) : nil
            }
        }
    }
}

public struct WorktimeReviewProposal: Sendable {
    fileprivate let stored: StoredReviewPreview
    public let before: WorktimeGlance
    public let after: WorktimeGlance

    public var selection: ObservationGap {
        stored.preview.review.selection
    }

    public var classification: ReviewClassification {
        stored.preview.review.classification
    }

    public var observedAt: Int64 {
        stored.preview.review.reviewedAt
    }
}

public enum FutureRestChangeError: Error, Equatable {
    case staleContext, invalidMinutes
}

/// A single-owner application session. Callers must discard the controller after clock or storage errors.
public struct WorktimeController {
    private let repository: CatalogRepository
    private var session: CatalogSession
    private var clock: ClockObservation
    private var checkpointVersion: StoreVersion?
    private var checkpointAt: Int64?

    public init(url: URL, createIfMissing: Bool = false, sample: ClockSample) throws {
        repository = try CatalogRepository(url: url, createIfMissing: createIfMissing)
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

    public mutating func perform(_ command: WorkdayCommand, sample: ClockSample) throws -> WorktimeGlance? {
        try observe(sample)
        session = try repository.apply(command, at: sample.wall, now: sample.wall, expected: session.version)
        try saveCheckpoint(sample: sample, afterMutation: true)
        return try glance(now: sample.wall)
    }

    /// Save a remaining-rest forecast only, fenced by the displayed day and current store version.
    public mutating func setFutureRest(
        minutes: Int?, expectedDay: Workday, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard session.catalog.days.last == expectedDay, session.catalog.activeID == expectedDay.id else {
            throw FutureRestChangeError.staleContext
        }
        if let minutes, !NextDaySettings.restRange.contains(minutes) {
            throw FutureRestChangeError.invalidMinutes
        }
        var updated = clock
        guard try updated.advance(to: sample) == nil else { throw FutureRestChangeError.staleContext }
        session = try repository.setFutureRest(
            dayID: expectedDay.id, remainingSeconds: minutes.map { Int64($0) * 60 },
            now: sample.wall, expected: session.version
        )
        clock = updated
        try saveCheckpoint(sample: sample, afterMutation: true)
        return try glance(now: sample.wall)
    }

    public mutating func previewReview(
        selection: ObservationGap, classification: ReviewClassification, sample: ClockSample
    ) throws -> WorktimeReviewProposal {
        try observe(sample)
        try saveCheckpoint(sample: sample)
        guard let before = try glance(now: sample.wall) else { throw WorkdayError.noActiveDay }
        let stored = try session.previewReview(
            dayID: before.day.id, selection: selection, classification: classification, now: sample.wall
        )
        var proposed = session.catalog
        try proposed.commitReview(stored.preview, now: sample.wall)
        let after = try WorktimeGlance(catalog: proposed, now: sample.wall)
        return WorktimeReviewProposal(stored: stored, before: before, after: after)
    }

    public func isCurrent(_ proposal: WorktimeReviewProposal) -> Bool {
        session.version == proposal.stored.version && session.catalog.days.contains(proposal.before.day)
    }

    public mutating func commitReview(
        _ proposal: WorktimeReviewProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        try observe(sample)
        guard isCurrent(proposal) else { throw SnapshotStoreError.staleVersion }
        session = try repository.commitReview(proposal.stored, now: sample.wall)
        try saveCheckpoint(sample: sample, afterMutation: true)
        return try glance(now: sample.wall)
    }

    /// Preview on a copy. Neither observation nor persistence is changed by previewing.
    public func previewRetrospectiveStart(
        at instant: Int64, profile: WorkdayProfile, sample: ClockSample
    ) throws -> RetrospectiveStartProposal {
        var observation = clock
        _ = try observation.advance(to: sample)
        let stored = try repository.load(now: sample.wall)
        guard stored.version == session.version else { throw SnapshotStoreError.staleVersion }
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
            version: stored.version, command: command, startedAt: instant, preparedAt: sample.wall, preview: preview
        )
    }

    /// One journal event with the asserted start and the actual confirmation time.
    public mutating func commitRetrospectiveStart(
        _ proposal: RetrospectiveStartProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard session.version == proposal.version, session.catalog.activeID == nil,
              sample.wall >= proposal.preparedAt else { throw RetrospectiveStartError.staleProposal }
        var updated = clock
        guard try updated.advance(to: sample) == nil else { throw RetrospectiveStartError.staleProposal }
        session = try repository.apply(
            proposal.command, at: proposal.startedAt, now: sample.wall, expected: proposal.version
        )
        clock = updated
        try saveCheckpoint(sample: sample, afterMutation: true)
        return try glance(now: sample.wall)
    }

    /// One committed snapshot, with no observation or persistence side effects.
    public func recentHistory(
        now: Int64, offset: Int = 0, previous: WorktimeHistory? = nil
    ) throws -> WorktimeHistory {
        let stored = try repository.revalidate(session, now: now)
        if let previous {
            guard previous.version == stored.version else { throw WorktimeHistoryError.stalePage }
        } else if offset != 0 {
            throw WorktimeHistoryError.stalePage
        }
        return try WorktimeHistory(session: stored, now: now, offset: offset)
    }

    /// Export only the committed journal, never an unsaved review proposal.
    public func writeBackup(to url: URL, now: Int64) throws {
        try repository.writeBackup(to: url, now: now, expected: session.version)
    }

    public func writeCSV(to url: URL, now: Int64) throws {
        try repository.writeCSV(to: url, now: now, expected: session.version)
    }

    /// Read only committed state; an unobserved gap or unreliable clock must not produce a precise reminder.
    public func reminderState(
        sample: ClockSample, departureLeads: Set<ReminderLead> = [.fifteen],
        earliestLeads: Set<ReminderLead> = [], referenceEnabled: Bool = false
    ) throws -> ReminderSyncState? {
        var observation = clock
        guard try observation.advance(to: sample) == nil else { return nil }
        let stored = try repository.revalidate(session, now: sample.wall)
        guard !stored.catalog.days.isEmpty else { return nil }
        let glance = try WorktimeGlance(catalog: stored.catalog, now: sample.wall)
        let basis = try glance.departureReminderBasis()
        let desired = ReminderPlan.desired(
            forecast: glance.forecast.goal, now: sample.wall, clockTrusted: true,
            departureLeads: departureLeads, earliestLeads: earliestLeads,
            referenceAt: referenceEnabled ? glance.day.profile.reference?.referenceAt : nil, departureBasis: basis
        )
        return ReminderSyncState(
            epoch: stored.version.epoch, dayID: glance.day.id, revision: stored.version.revision, desired: desired
        )
    }

    private var activeWorkingDay: Workday? {
        guard let day = session.catalog.days.last, day.state == .working else { return nil }
        return day
    }

    private mutating func recoverOpenInterval(sample: ClockSample) throws {
        guard let day = activeWorkingDay, let start = day.intervals.last?.start else { return }
        var unknownStart = start
        if let marker = try repository.loadObservationCheckpoint(expected: session.version), marker.dayID == day.id {
            guard marker.observedAt <= sample.wall else { throw ApplicationClockError.unreliableClock }
            unknownStart = max(start, marker.observedAt)
        }
        if unknownStart < sample.wall {
            try record(dayID: day.id, gap: .init(start: unknownStart, end: sample.wall), now: sample.wall)
        }
    }

    /// Persist only after clock observation and any gap/command/review commits have succeeded.
    private mutating func saveCheckpoint(sample: ClockSample, afterMutation: Bool = false) throws {
        guard let day = activeWorkingDay else {
            checkpointVersion = nil
            checkpointAt = nil
            return
        }
        if checkpointVersion == session.version, let checkpointAt, sample.wall - checkpointAt < 10 {
            return
        }
        try repository.persistCheckpoint(dayID: day.id, at: sample.wall,
                                         version: session.version, afterMutation: afterMutation)
        checkpointVersion = session.version
        checkpointAt = sample.wall
    }

    private mutating func observe(_ sample: ClockSample) throws {
        var updated = clock
        let gap = try updated.advance(to: sample)
        if let gap, let day = activeWorkingDay, let start = day.intervals.last?.start {
            let clipped = max(start, gap.start)
            if clipped < gap.end {
                try record(dayID: day.id, gap: .init(start: clipped, end: gap.end), now: sample.wall)
            }
        }
        clock = updated
    }

    private mutating func record(dayID: UUID, gap: ObservationGap, now: Int64) throws {
        session = try repository.recordObservation(dayID: dayID, gap: gap, now: now, expected: session.version)
    }

    private func glance(now: Int64) throws -> WorktimeGlance? {
        guard !session.catalog.days.isEmpty else { return nil }
        return try WorktimeGlance(catalog: session.catalog, now: now)
    }
}

public enum DesiredDepartureSaveError: Error, Equatable {
    case staleProposal, confirmationRequired, invalidCandidate
}

public struct DesiredDepartureProposal: Sendable {
    fileprivate let version: StoreVersion
    fileprivate let dayID: UUID
    public let assessment: DesiredDepartureAssessment
}

public extension WorktimeController {
    /// Read-only preview; no observation or journal write occurs.
    func previewDesiredDeparture(at candidate: Int64, sample: ClockSample) throws -> DesiredDepartureProposal {
        var updated = clock
        guard try updated.advance(to: sample) == nil else { throw DesiredDepartureSaveError.staleProposal }
        let stored = try repository.load(now: sample.wall)
        guard stored.version == session.version, stored.catalog.activeID != nil else {
            throw DesiredDepartureSaveError.staleProposal
        }
        let glance = try WorktimeGlance(catalog: stored.catalog, now: sample.wall)
        let assessment = try glance.assessDesiredDeparture(at: candidate)
        guard assessment.canSave(warningAcknowledged: true) else {
            throw DesiredDepartureSaveError.invalidCandidate
        }
        return DesiredDepartureProposal(version: stored.version, dayID: glance.day.id, assessment: assessment)
    }

    /// Recheck the latest forecast before saving an explicit intention.
    mutating func commitDesiredDeparture(
        _ proposal: DesiredDepartureProposal, warningAcknowledged: Bool, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard proposal.version == session.version, session.catalog.activeID == proposal.dayID,
              sample.wall >= proposal.assessment.scenario.observedAt
        else {
            throw DesiredDepartureSaveError.staleProposal
        }
        let fresh = try previewDesiredDeparture(at: proposal.assessment.scenario.candidate, sample: sample)
        guard fresh.assessment.status == proposal.assessment.status,
              fresh.assessment.scenario.result == proposal.assessment.scenario.result
        else {
            throw DesiredDepartureSaveError.staleProposal
        }
        guard fresh.assessment.canSave(warningAcknowledged: warningAcknowledged) else {
            throw DesiredDepartureSaveError.confirmationRequired
        }
        var updated = clock
        guard try updated.advance(to: sample) == nil else { throw DesiredDepartureSaveError.staleProposal }
        session = try repository.setDesiredDeparture(
            dayID: proposal.dayID, candidate: proposal.assessment.scenario.candidate,
            warningAcknowledged: warningAcknowledged, now: sample.wall, expected: proposal.version
        )
        clock = updated
        try saveCheckpoint(sample: sample, afterMutation: true)
        return try glance(now: sample.wall)
    }

    mutating func clearDesiredDeparture(expectedDay: Workday, sample: ClockSample) throws -> WorktimeGlance? {
        guard session.catalog.days.last == expectedDay, session.catalog.activeID == expectedDay.id else {
            throw DesiredDepartureSaveError.staleProposal
        }
        var updated = clock
        guard try updated.advance(to: sample) == nil else { throw DesiredDepartureSaveError.staleProposal }
        session = try repository.setDesiredDeparture(
            dayID: expectedDay.id, candidate: nil, warningAcknowledged: false,
            now: sample.wall, expected: session.version
        )
        clock = updated
        try saveCheckpoint(sample: sample, afterMutation: true)
        return try glance(now: sample.wall)
    }
}

public struct WorktimeRollbackProposal: Sendable {
    fileprivate let stored: CatalogRollbackProposal

    public var currentDays: Int {
        stored.currentDays
    }

    public var restoredDays: Int {
        stored.restoredDays
    }

    public var currentRevision: Int64 {
        stored.currentVersion.revision
    }

    public var sourceRevision: Int64 {
        stored.sourceVersion.revision
    }
}

public extension WorktimeController {
    /// Does not write, resolve observation gaps, or reopen a selected backup.
    func previewRollback(file: URL, sample: ClockSample) throws -> WorktimeRollbackProposal {
        var checked = clock
        _ = try checked.advance(to: sample)
        let proposal = try repository.previewRollback(file: file, now: sample.wall, expected: session.version)
        return WorktimeRollbackProposal(stored: proposal)
    }

    func isCurrent(_ proposal: WorktimeRollbackProposal) -> Bool {
        session.version == proposal.stored.currentVersion && session.catalog.activeID == nil
    }

    /// Caller must quiesce notification scheduling and all writers. Discard this controller afterwards.
    func commitRollback(
        _ proposal: WorktimeRollbackProposal, preserveCurrentAt destination: URL, sample: ClockSample
    ) throws {
        guard isCurrent(proposal) else { throw SnapshotStoreError.staleVersion }
        var checked = clock
        _ = try checked.advance(to: sample)
        _ = try repository.commitRollback(proposal.stored, preserveCurrentAt: destination, now: sample.wall)
    }
}

public extension WorktimeController {
    /// Select only a completed historical day from the exact displayed history snapshot.
    func historicalReviewContext(
        dayID: UUID, history: WorktimeHistory, sample: ClockSample
    ) throws -> HistoricalReviewContext {
        var checked = clock
        _ = try checked.advance(to: sample)
        let stored = try repository.revalidate(session, now: sample.wall)
        guard stored.version == history.version,
              history.rows.contains(where: { $0.id == dayID }), stored.catalog.days.last?.id != dayID
        else { throw HistoricalReviewError.staleContext }
        let selected = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: dayID)
        guard selected.day.state == .ended else { throw HistoricalReviewError.staleContext }
        return HistoricalReviewContext(version: stored.version, glance: selected)
    }

    func isCurrent(_ context: HistoricalReviewContext) -> Bool {
        session.version == context.version && session.catalog.days.last?.id != context.glance.day.id &&
            session.catalog.days.contains(context.glance.day)
    }

    /// Value-copy preview of a historical day without changing the latest glance or writing a journal.
    func previewHistoricalReview(
        _ context: HistoricalReviewContext, selection: ObservationGap,
        source: ObservationGap, classification: ReviewClassification, sample: ClockSample
    ) throws -> WorktimeReviewProposal {
        guard isCurrent(context), context.glance.reviewableGaps.contains(source),
              selection.start >= source.start, selection.end <= source.end, selection.start < selection.end
        else { throw HistoricalReviewError.staleContext }
        var checked = clock
        _ = try checked.advance(to: sample)
        let current = try repository.revalidate(session, now: sample.wall)
        let id = context.glance.day.id
        let before = try WorktimeGlance(catalog: current.catalog, now: sample.wall, dayID: id)
        let stored = try current.previewReview(dayID: id, selection: selection,
                                               classification: classification, now: sample.wall)
        var proposed = current.catalog
        try proposed.commitReview(stored.preview, now: sample.wall)
        let after = try WorktimeGlance(catalog: proposed, now: sample.wall, dayID: id)
        return WorktimeReviewProposal(stored: stored, before: before, after: after)
    }
}

public extension WorktimeController {
    /// Explicit read of committed history; period navigation never writes observations or reminders.
    func summary(
        period: WorktimeSummaryPeriod, sample: ClockSample, previous: WorktimeSummary? = nil
    ) throws -> WorktimeSummary {
        var checked = clock
        _ = try checked.advance(to: sample)
        let stored = try repository.revalidate(session, now: sample.wall)
        if let previous, previous.version != stored.version {
            throw WorktimeSummaryError.staleSummary
        }
        return try WorktimeSummary(session: stored, period: period, now: sample.wall)
    }

    func isCurrent(_ summary: WorktimeSummary) -> Bool {
        session.version == summary.version
    }
}

public extension WorktimeController {
    /// Export exactly the displayed committed summary after revalidating its source.
    func writeSummaryCSV(_ displayed: WorktimeSummary, to url: URL, sample: ClockSample) throws {
        let current = try summary(period: displayed.period, sample: sample, previous: displayed)
        guard current.daily == displayed.daily, current.worked == displayed.worked,
              current.target == displayed.target, current.recordedRest == displayed.recordedRest,
              current.endedDays == displayed.endedDays, current.uncertainDays == displayed.uncertainDays,
              current.dailyShortfall == displayed.dailyShortfall, current.dailySurplus == displayed.dailySurplus
        else { throw WorktimeSummaryError.staleSummary }
        try BackupFile.publish(WorktimeSummaryCSV.encode(displayed), to: url)
    }
}

public extension WorktimeController {
    func previewReset(sample: ClockSample) throws -> CatalogResetProposal {
        var checked = clock
        _ = try checked.advance(to: sample)
        return try repository.previewReset(now: sample.wall, expected: session.version)
    }

    func isCurrent(_ proposal: CatalogResetProposal) -> Bool {
        session.version == proposal.version
    }

    /// Quiesce all application writers and owned notifications, then discard this controller.
    func commitReset(_ proposal: CatalogResetProposal, sample: ClockSample) throws {
        guard isCurrent(proposal) else { throw SnapshotStoreError.staleVersion }
        var checked = clock
        _ = try checked.advance(to: sample)
        _ = try repository.commitReset(proposal, now: sample.wall)
    }
}
