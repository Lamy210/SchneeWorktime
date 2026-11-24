import Foundation
import WorktimeDomain

/// Preview must be confirmed against the exact original Journal and checkpoint state.
public struct JournalV2ReviewProposal {
    public let version: StoreVersion
    public let preview: CatalogReviewPreview
    fileprivate let source: JournalV2Session
}

public struct JournalV2RestCorrectionProposal {
    public let version: StoreVersion
    public let preview: RestEndCorrectionPreview
    fileprivate let source: JournalV2Session
}

public struct JournalV2ClockOutCorrectionProposal {
    public let version: StoreVersion
    public let preview: ClockOutCorrectionPreview
    fileprivate let source: JournalV2Session
}

public struct JournalV2ClockInCorrectionProposal {
    public let version: StoreVersion
    public let preview: ClockInCorrectionPreview
    fileprivate let source: JournalV2Session
}

public extension JournalV2Repository {
    /// Read-only uncertainty review preview, pinned to all event bytes and checkpoint metadata.
    func previewReview(
        dayID: UUID, selection: ObservationGap, classification: ReviewClassification,
        now: Int64, matching session: JournalV2Session
    ) throws -> JournalV2ReviewProposal {
        let current = try revalidate(session, now: now)
        let preview = try current.catalog.previewReview(
            dayID: dayID, selection: selection, classification: classification, now: now
        )
        return JournalV2ReviewProposal(version: current.version, preview: preview, source: current)
    }

    /// The domain preview is rechecked, then the correction is written as an audit event.
    func commitReview(_ proposal: JournalV2ReviewProposal, now: Int64) throws -> JournalV2Session {
        let source = try revalidate(proposal.source, now: now)
        var expected = source.catalog
        try expected.commitReview(proposal.preview, now: now)
        let preview = proposal.preview
        let selection = preview.review.selection
        let action = JournalAction.review(
            dayID: preview.dayID, start: selection.start, end: selection.end,
            classification: JournalClassification(preview.review.classification)
        )
        return try commitVerified(
            JournalEvent(action: action, now: now), matching: source, previewedCatalog: expected
        )
    }

    func previewRestEndCorrection(
        dayID: UUID, oldEnd: Int64, newEnd: Int64,
        now: Int64, matching session: JournalV2Session
    ) throws -> JournalV2RestCorrectionProposal {
        let current = try revalidate(session, now: now)
        let preview = try current.catalog.previewRestEndCorrection(
            dayID: dayID, oldEnd: oldEnd, newEnd: newEnd, now: now
        )
        return JournalV2RestCorrectionProposal(version: current.version, preview: preview, source: current)
    }

    func previewRestStartCorrection(
        dayID: UUID, oldStart: Int64, newStart: Int64,
        now: Int64, matching session: JournalV2Session
    ) throws -> JournalV2RestCorrectionProposal {
        let current = try revalidate(session, now: now)
        let preview = try current.catalog.previewRestStartCorrection(
            dayID: dayID, oldStart: oldStart, newStart: newStart, now: now
        )
        return JournalV2RestCorrectionProposal(version: current.version, preview: preview, source: current)
    }

    func commitRestEndCorrection(
        _ proposal: JournalV2RestCorrectionProposal, now: Int64
    ) throws -> JournalV2Session {
        guard proposal.preview.boundary == .end else { throw RestEndCorrectionError.changedPreview }
        return try commitRestBoundary(proposal, now: now)
    }

    func commitRestStartCorrection(
        _ proposal: JournalV2RestCorrectionProposal, now: Int64
    ) throws -> JournalV2Session {
        guard proposal.preview.boundary == .start else { throw RestEndCorrectionError.changedPreview }
        return try commitRestBoundary(proposal, now: now)
    }

    func previewClockOutCorrection(
        dayID: UUID, oldEnd: Int64, newEnd: Int64,
        now: Int64, matching session: JournalV2Session
    ) throws -> JournalV2ClockOutCorrectionProposal {
        let current = try revalidate(session, now: now)
        let preview = try current.catalog.previewClockOutCorrection(
            dayID: dayID, oldEnd: oldEnd, newEnd: newEnd, now: now
        )
        return JournalV2ClockOutCorrectionProposal(version: current.version, preview: preview, source: current)
    }

    func commitClockOutCorrection(
        _ proposal: JournalV2ClockOutCorrectionProposal, now: Int64
    ) throws -> JournalV2Session {
        let source = try revalidate(proposal.source, now: now)
        var expected = source.catalog
        try expected.commitClockOutCorrection(proposal.preview, now: now)
        let preview = proposal.preview
        let action = JournalAction.correctClockOut(
            dayID: preview.dayID, oldEnd: preview.oldEnd, newEnd: preview.newEnd
        )
        return try commitVerified(
            JournalEvent(action: action, now: now), matching: source, previewedCatalog: expected
        )
    }

    func previewClockInCorrection(
        dayID: UUID, oldStart: Int64, newStart: Int64,
        now: Int64, matching session: JournalV2Session
    ) throws -> JournalV2ClockInCorrectionProposal {
        let current = try revalidate(session, now: now)
        let preview = try current.catalog.previewClockInCorrection(
            dayID: dayID, oldStart: oldStart, newStart: newStart, now: now
        )
        return JournalV2ClockInCorrectionProposal(version: current.version, preview: preview, source: current)
    }

    func commitClockInCorrection(
        _ proposal: JournalV2ClockInCorrectionProposal, now: Int64
    ) throws -> JournalV2Session {
        let source = try revalidate(proposal.source, now: now)
        var expected = source.catalog
        try expected.commitClockInCorrection(proposal.preview, now: now)
        let action = JournalAction.correctClockIn(proposal.preview.record)
        return try commitVerified(
            JournalEvent(action: action, now: now), matching: source, previewedCatalog: expected
        )
    }

    private func commitRestBoundary(
        _ proposal: JournalV2RestCorrectionProposal, now: Int64
    ) throws -> JournalV2Session {
        let source = try revalidate(proposal.source, now: now)
        var expected = source.catalog
        let preview = proposal.preview
        let action: JournalAction
        switch preview.boundary {
        case .start:
            try expected.commitRestStartCorrection(preview, now: now)
            action = .correctRestStart(
                dayID: preview.dayID, oldStart: preview.oldEnd, newStart: preview.newEnd
            )
        case .end:
            try expected.commitRestEndCorrection(preview, now: now)
            action = .correctRestEnd(dayID: preview.dayID, oldEnd: preview.oldEnd, newEnd: preview.newEnd)
        }
        return try commitVerified(
            JournalEvent(action: action, now: now), matching: source, previewedCatalog: expected
        )
    }
}
