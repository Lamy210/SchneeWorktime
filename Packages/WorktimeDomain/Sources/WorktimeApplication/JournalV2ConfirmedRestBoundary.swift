import WorktimeDomain

/// Explicitly confirmed edit of an existing work/rest boundary.
public struct JournalV2RestBoundaryIntent: Equatable, Sendable {
    public let boundary: RestBoundary
    public let old: Int64
    public let new: Int64

    public init(boundary: RestBoundary, old: Int64, new: Int64) {
        self.boundary = boundary
        self.old = old
        self.new = new
    }
}

public struct JournalV2ConfirmedRestBoundary {
    public let intent: JournalV2RestBoundaryIntent
    public let correction: JournalV2WorktimeCorrectionProposal
    let context: JournalV2WorkActionContext
    let historical: HistoricalReviewContext?
}

public extension JournalV2WorktimeController {
    func previewConfirmedRestBoundary(
        _ intent: JournalV2RestBoundaryIntent, day: Workday,
        historical: HistoricalReviewContext? = nil,
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> JournalV2ConfirmedRestBoundary {
        guard expected == workActionContext, expected.canAppend else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        let correction = try previewRestBoundaryCorrection(
            expectedDay: day, old: intent.old, new: intent.new,
            boundary: intent.boundary, historical: historical, sample: sample
        )
        return JournalV2ConfirmedRestBoundary(
            intent: intent, correction: correction, context: expected, historical: historical
        )
    }

    func isCurrent(_ proposal: JournalV2ConfirmedRestBoundary) -> Bool {
        workActionContext.canAppend &&
            workActionContext.permitsRoutineObservation(since: proposal.context) &&
            isCurrent(proposal.correction)
    }

    /// Rebuild the exact intent against the current owned session. The clock
    /// may advance, but neither the affected intervals nor their effect may change.
    mutating func commitConfirmedRestBoundary(
        _ proposal: JournalV2ConfirmedRestBoundary, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard isCurrent(proposal) else { throw JournalV2WorktimeCorrectionError.staleProposal }
        let fresh = try previewConfirmedRestBoundary(
            proposal.intent, day: proposal.correction.before.day, historical: proposal.historical,
            matching: workActionContext, sample: sample
        )
        guard Self.sameRestBoundaryEffect(proposal.correction, fresh.correction) else {
            throw JournalV2WorktimeCorrectionError.staleProposal
        }
        return try commitCorrection(fresh.correction, sample: sample)
    }

    private static func sameRestBoundaryEffect(
        _ original: JournalV2WorktimeCorrectionProposal, _ fresh: JournalV2WorktimeCorrectionProposal
    ) -> Bool {
        original.kind == fresh.kind && original.version == fresh.version &&
            original.before.day == fresh.before.day && original.after.day == fresh.after.day &&
            original.before.reviewableGaps == fresh.before.reviewableGaps &&
            original.after.reviewableGaps == fresh.after.reviewableGaps &&
            restBoundaryDeltas(original) == restBoundaryDeltas(fresh)
    }

    private static func restBoundaryDeltas(_ value: JournalV2WorktimeCorrectionProposal) -> [Int64] {
        let before = value.before.snapshot
        let after = value.after.snapshot
        return [
            after.bounds.lower - before.bounds.lower,
            after.bounds.upper - before.bounds.upper,
            after.recordedRest - before.recordedRest
        ]
    }
}
