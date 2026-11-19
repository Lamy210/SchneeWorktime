import Foundation

public enum ClockInCorrectionError: Error, Equatable {
    case invalidBoundary, overlapsPreviousDay, overlapsUncertainty, changesReference, crossesRestAnchor, changedPreview
}

public struct ClockInCorrectionRecord: Sendable, Equatable, Codable {
    public let dayID: UUID
    public let oldStart: Int64
    public let newStart: Int64
    public let beforeReference: CapturedReference?
    public let afterReference: CapturedReference?

    public init(
        dayID: UUID, oldStart: Int64, newStart: Int64,
        beforeReference: CapturedReference?, afterReference: CapturedReference?
    ) {
        self.dayID = dayID
        self.oldStart = oldStart
        self.newStart = newStart
        self.beforeReference = beforeReference
        self.afterReference = afterReference
    }
}

public struct ClockInCorrectionPreview: Sendable, Equatable {
    public let dayID: UUID
    public let version: ReviewVersion
    public let before: Workday
    public let after: Workday
    public let review: HistoryReviewResult
    public let record: ClockInCorrectionRecord
}

public extension WorkdayCatalog {
    /// Only ended days and their first closed work interval. No persistence or mutation.
    func previewClockInCorrection(
        dayID: UUID, oldStart: Int64, newStart: Int64, now: Int64
    ) throws -> ClockInCorrectionPreview {
        guard let day = days.first(where: { $0.id == dayID }) else { throw CatalogReviewError.unknownDay }
        let profile = try correctedStartProfile(day.profile, at: newStart)
        let record = ClockInCorrectionRecord(
            dayID: dayID, oldStart: oldStart, newStart: newStart,
            beforeReference: day.profile.reference, afterReference: profile.reference
        )
        return try clockInReplayPreview(record, now: now)
    }

    /// Replay uses captured reference evidence, not the current timezone database.
    internal func clockInReplayPreview(_ record: ClockInCorrectionRecord, now: Int64) throws -> ClockInCorrectionPreview {
        let dayID = record.dayID
        let oldStart = record.oldStart
        let newStart = record.newStart
        guard let index = days.firstIndex(where: { $0.id == dayID }) else { throw CatalogReviewError.unknownDay }
        let day = days[index]
        guard day.state == .ended, let first = day.intervals.first, first.kind == .work,
              let end = first.end, first.start == oldStart, newStart != oldStart,
              newStart < end, newStart <= now
        else { throw ClockInCorrectionError.invalidBoundary }
        if index > 0 {
            if let previousEnd = days[index - 1].intervals.last?.end, newStart < previousEnd {
                throw ClockInCorrectionError.overlapsPreviousDay
            }
        }
        if let anchor = day.futureRestPlan?.plan.anchor, newStart > anchor {
            throw ClockInCorrectionError.crossesRestAnchor
        }
        _ = try snapshot(dayID: dayID, now: now)
        let selection = ObservationGap(start: min(oldStart, newStart), end: max(oldStart, newStart))
        let gaps = observations[dayID] ?? []
        guard !gaps.contains(where: { $0.start < selection.end && selection.start < $0.end }) else {
            throw ClockInCorrectionError.overlapsUncertainty
        }
        let profile = try replayStartProfile(day.profile, record: record)
        var intervals = day.intervals
        intervals[0] = .init(start: newStart, end: end, kind: .work)
        let updated = Workday(id: day.id, profile: profile, state: day.state, intervals: intervals,
                              revision: day.revision, futureRestPlan: day.futureRestPlan)
        _ = try updated.snapshot(now: now, uncertainty: gaps)
        let review = HistoryReviewResult(
            selection: selection, classification: newStart < oldStart ? .work : .gap, reviewedAt: now,
            beforeIntervals: day.intervals, beforeUncertainty: gaps,
            afterIntervals: intervals, afterUncertainty: gaps
        )
        return ClockInCorrectionPreview(dayID: dayID, version: reviewVersion, before: day,
                                        after: updated, review: review, record: record)
    }

    private func replayStartProfile(
        _ profile: WorkdayProfile, record: ClockInCorrectionRecord
    ) throws -> WorkdayProfile {
        guard profile.reference == record.beforeReference else { throw ClockInCorrectionError.changesReference }
        switch (record.beforeReference, record.afterReference) {
        case (nil, nil):
            return profile
        case let (original?, updated?):
            try original.validate(startedAt: record.oldStart)
            try updated.validate(startedAt: record.newStart)
            guard original.timeZoneID == updated.timeZoneID, original.logicalDate == updated.logicalDate,
                  original.wallTime == updated.wallTime, original.resolution == updated.resolution
            else { throw ClockInCorrectionError.changesReference }
            return try WorkdayProfile(target: profile.target, expectedRest: profile.expectedRest, reference: updated)
        default:
            throw ClockInCorrectionError.changesReference
        }
    }

    private func correctedStartProfile(_ profile: WorkdayProfile, at instant: Int64) throws -> WorkdayProfile {
        guard let original = profile.reference else { return profile }
        let updated = try CapturedReference(
            startedAt: instant, timeZoneID: original.timeZoneID, wallTime: original.wallTime
        )
        guard updated.logicalDate == original.logicalDate, updated.resolution == original.resolution else {
            throw ClockInCorrectionError.changesReference
        }
        return try WorkdayProfile(target: profile.target, expectedRest: profile.expectedRest, reference: updated)
    }
}
