import WorktimeDomain
import WorktimeStore

public extension WorktimeController {
    func previewRestEndCorrection(
        expectedDay: Workday, oldEnd: Int64, newEnd: Int64,
        historical: HistoricalReviewContext? = nil, sample: ClockSample
    ) throws -> WorktimeRestEndProposal {
        try previewRestBoundaryCorrection(
            expectedDay: expectedDay, old: oldEnd, new: newEnd, boundary: .end,
            historical: historical, sample: sample
        )
    }

    func previewRestBoundaryCorrection(
        expectedDay: Workday, old: Int64, new: Int64, boundary: RestBoundary,
        historical: HistoricalReviewContext? = nil, sample: ClockSample
    ) throws -> WorktimeRestEndProposal {
        let stored = try correctionSession(
            expectedDay: expectedDay, historical: historical, sample: sample,
            stale: RestEndInteractionError.staleProposal
        )
        let preview: StoredRestEndCorrection
        var proposed = stored.catalog
        switch boundary {
        case .start:
            preview = try stored.previewRestStartCorrection(
                dayID: expectedDay.id, oldStart: old, newStart: new, now: sample.wall
            )
            try proposed.commitRestStartCorrection(preview.preview, now: sample.wall)
        case .end:
            preview = try stored.previewRestEndCorrection(
                dayID: expectedDay.id, oldEnd: old, newEnd: new, now: sample.wall
            )
            try proposed.commitRestEndCorrection(preview.preview, now: sample.wall)
        }
        let before = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: expectedDay.id)
        let after = try WorktimeGlance(catalog: proposed, now: sample.wall, dayID: expectedDay.id)
        return WorktimeRestEndProposal(stored: preview, before: before, after: after)
    }

    func isCurrent(_ proposal: WorktimeRestEndProposal) -> Bool {
        isCurrentCorrection(version: proposal.stored.version, day: proposal.before.day)
    }

    mutating func commitRestEndCorrection(
        _ proposal: WorktimeRestEndProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard proposal.boundary == .end else { throw RestEndInteractionError.staleProposal }
        return try commitRestBoundaryCorrection(proposal, sample: sample)
    }

    mutating func commitRestBoundaryCorrection(
        _ proposal: WorktimeRestEndProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        try commitCorrection(
            version: proposal.stored.version, day: proposal.before.day, sample: sample,
            stale: RestEndInteractionError.staleProposal
        ) { repository in
            switch proposal.boundary {
            case .start:
                try repository.commitRestStartCorrection(proposal.stored, now: sample.wall)
            case .end:
                try repository.commitRestEndCorrection(proposal.stored, now: sample.wall)
            }
        }
    }
}

public extension WorktimeController {
    func previewClockOutCorrection(
        expectedDay: Workday, oldEnd: Int64, newEnd: Int64,
        historical: HistoricalReviewContext? = nil, sample: ClockSample
    ) throws -> WorktimeClockOutProposal {
        let stored = try correctionSession(
            expectedDay: expectedDay, historical: historical, sample: sample,
            stale: ClockOutInteractionError.staleProposal
        )
        let preview = try stored.previewClockOutCorrection(
            dayID: expectedDay.id, oldEnd: oldEnd, newEnd: newEnd, now: sample.wall
        )
        var proposed = stored.catalog
        try proposed.commitClockOutCorrection(preview.preview, now: sample.wall)
        let before = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: expectedDay.id)
        let after = try WorktimeGlance(catalog: proposed, now: sample.wall, dayID: expectedDay.id)
        return WorktimeClockOutProposal(stored: preview, before: before, after: after)
    }

    func isCurrent(_ proposal: WorktimeClockOutProposal) -> Bool {
        isCurrentCorrection(version: proposal.stored.version, day: proposal.before.day)
    }

    mutating func commitClockOutCorrection(
        _ proposal: WorktimeClockOutProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        try commitCorrection(
            version: proposal.stored.version, day: proposal.before.day, sample: sample,
            stale: ClockOutInteractionError.staleProposal
        ) { repository in
            try repository.commitClockOutCorrection(proposal.stored, now: sample.wall)
        }
    }
}
