import Foundation
import WorktimeDomain
import WorktimeStore

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
