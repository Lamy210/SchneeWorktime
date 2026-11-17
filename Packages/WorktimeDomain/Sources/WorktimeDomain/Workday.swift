import Foundation

public enum WorkdayState: Sendable, Equatable {
    case working, onBreak, ended
}

public enum WorkdayError: Error, Equatable {
    case staleRevision, revisionOverflow, activeDayExists, noActiveDay
    case duplicateID, invalidTransition, confirmationRequired, invalidEventTime
    case zeroLengthInterval, notLatestEndedDay, invalidProfile
}

public struct WorkdayProfile: Sendable, Equatable {
    public let target: Int64
    public let expectedRest: Int64
    public let reference: CapturedReference?

    public init(target: Int64 = 25200, expectedRest: Int64 = 3600, reference: CapturedReference? = nil) throws {
        guard target > 0, expectedRest >= 0 else { throw WorkdayError.invalidProfile }
        self.target = target
        self.expectedRest = expectedRest
        self.reference = reference
    }
}

public struct FutureRestPlan: Sendable, Equatable {
    public let plan: RestPlan
    public let revision: UInt64
}

public struct Workday: Sendable, Equatable {
    public let id: UUID
    public let profile: WorkdayProfile
    public let state: WorkdayState
    public let intervals: [RecordedInterval]
    public internal(set) var revision: UInt64
    public internal(set) var futureRestPlan: FutureRestPlan?

    public func snapshot(now: Int64, uncertainty: [ObservationGap] = []) throws -> TimelineSnapshot {
        guard let last = intervals.last, now >= last.start else { throw WorkdayError.invalidEventTime }
        if let end = last.end, now < end {
            throw WorkdayError.invalidEventTime
        }
        let evaluation = last.end ?? now
        var relevant: [ObservationGap] = []
        for gap in uncertainty {
            guard gap.start < gap.end, gap.end <= now else { throw WorktimeError.invalidInterval }
            if gap.start < evaluation {
                relevant.append(.init(start: gap.start, end: min(gap.end, evaluation)))
            }
        }
        return try Timeline.snapshot(
            intervals: intervals, uncertainty: relevant, now: evaluation,
            target: profile.target, expectedRest: profile.expectedRest, override: futureRestPlan?.plan
        )
    }
}

public enum WorkdayCommand: Sendable, Equatable {
    case clockIn(id: UUID, profile: WorkdayProfile)
    case startBreak, endBreak
    case clockOut(confirmBreak: Bool)
    case resume(id: UUID)
}

/// Value-only aggregate. Its caller must serialize durable writes and use a trusted clock.
public struct WorkdayCatalog: Sendable, Equatable {
    public private(set) var days: [Workday] = []
    public private(set) var revision: UInt64 = 0
    public private(set) var observationGeneration: UInt64 = 0
    public private(set) var observations: [UUID: [ObservationGap]] = [:]
    public private(set) var reviewAudit: [WorkdayReviewAudit] = []
    public private(set) var desiredDepartures: [UUID: Int64] = [:]

    public init() {}

    public var activeID: UUID? {
        guard let last = days.last, last.state != .ended else { return nil }
        return last.id
    }

    public mutating func apply(
        _ command: WorkdayCommand, at instant: Int64, now: Int64, expectedRevision: UInt64
    ) throws {
        guard expectedRevision == revision else { throw WorkdayError.staleRevision }
        guard instant <= now else { throw WorkdayError.invalidEventTime }
        guard revision < UInt64.max else { throw WorkdayError.revisionOverflow }
        let next = revision + 1
        switch command {
        case let .clockIn(id, profile):
            guard activeID == nil else { throw WorkdayError.activeDayExists }
            guard !days.contains(where: { $0.id == id }) else { throw WorkdayError.duplicateID }
            if let end = days.last?.intervals.last?.end, instant < end {
                throw WorkdayError.invalidEventTime
            }
            try profile.reference?.validate(startedAt: instant)
            let day = Workday(id: id, profile: profile, state: .working,
                              intervals: [.init(start: instant, end: nil, kind: .work)], revision: next)
            _ = try day.snapshot(now: now)
            days.append(day)
        default:
            guard let day = days.last else { throw WorkdayError.noActiveDay }
            let updated = try Self.transition(day, command: command, at: instant, revision: next)
            _ = try updated.snapshot(now: now)
            days[days.count - 1] = updated
        }
        revision = next
    }

    /// Forecast only. Nil restores the initial daily profile budget, not zero.
    public mutating func setFutureRest(
        dayID: UUID, remainingSeconds: Int64?, now: Int64, expectedRevision: UInt64
    ) throws {
        guard expectedRevision == revision else { throw WorkdayError.staleRevision }
        guard let day = days.last, activeID == dayID else { throw WorkdayError.noActiveDay }
        guard let last = day.intervals.last, now >= last.start,
              now >= (day.futureRestPlan?.plan.anchor ?? last.start)
        else {
            throw WorkdayError.invalidEventTime
        }
        if let remainingSeconds, !(0 ... 86400).contains(remainingSeconds) {
            throw WorkdayError.invalidProfile
        }
        if remainingSeconds == nil, day.futureRestPlan == nil {
            return
        }
        guard revision < UInt64.max else {
            throw WorkdayError.revisionOverflow
        }
        let next = revision + 1
        let plan = remainingSeconds.map {
            FutureRestPlan(plan: RestPlan(anchor: now, remainingAtAnchor: $0), revision: next)
        }
        let updated = Workday(
            id: day.id, profile: day.profile, state: day.state, intervals: day.intervals,
            revision: next, futureRestPlan: plan
        )
        _ = try updated.snapshot(now: now, uncertainty: observations[dayID] ?? [])
        days[days.count - 1] = updated
        revision = next
    }

    private static func transition(
        _ day: Workday, command: WorkdayCommand, at instant: Int64, revision: UInt64
    ) throws -> Workday {
        guard let last = day.intervals.last else { throw WorkdayError.invalidTransition }
        var intervals = day.intervals
        let state: WorkdayState
        switch command {
        case .startBreak:
            guard day.state == .working else { throw WorkdayError.invalidTransition }
            try close(&intervals, at: instant)
            intervals.append(.init(start: instant, end: nil, kind: .rest))
            state = .onBreak
        case .endBreak:
            guard day.state == .onBreak else { throw WorkdayError.invalidTransition }
            try close(&intervals, at: instant)
            intervals.append(.init(start: instant, end: nil, kind: .work))
            state = .working
        case let .clockOut(confirmBreak):
            guard day.state != .ended else { throw WorkdayError.invalidTransition }
            if day.state == .onBreak, !confirmBreak {
                throw WorkdayError.confirmationRequired
            }
            try close(&intervals, at: instant)
            state = .ended
        case let .resume(id):
            guard day.id == id, day.state == .ended, let end = last.end else {
                throw WorkdayError.notLatestEndedDay
            }
            guard instant >= end else { throw WorkdayError.invalidEventTime }
            intervals.append(.init(start: instant, end: nil, kind: .work))
            state = .working
        case .clockIn:
            throw WorkdayError.invalidTransition
        }
        return Workday(
            id: day.id, profile: day.profile, state: state, intervals: intervals,
            revision: revision, futureRestPlan: day.futureRestPlan
        )
    }

    private static func close(_ intervals: inout [RecordedInterval], at instant: Int64) throws {
        guard let last = intervals.last, last.end == nil else { throw WorkdayError.invalidTransition }
        guard instant >= last.start else { throw WorkdayError.invalidEventTime }
        guard instant > last.start else { throw WorkdayError.zeroLengthInterval }
        intervals[intervals.count - 1] = .init(start: last.start, end: instant, kind: last.kind)
    }
}

public extension WorkdayCatalog {
    /// Save an intention without adding or closing actual work intervals.
    mutating func setDesiredDeparture(
        dayID: UUID, candidate: Int64?, warningAcknowledged: Bool,
        now: Int64, expected: ReviewVersion
    ) throws {
        try checkVersion(expected)
        guard var day = days.last, activeID == dayID else { throw WorkdayError.noActiveDay }
        let snapshot = try snapshot(dayID: dayID, now: now)
        if let candidate {
            guard candidate > now else { throw WorkdayError.invalidEventTime }
            let state: PreviewState = day.state == .working ? .working : .onBreak(returnAt: nil)
            let preview = try Worktime.preview(
                bounds: snapshot.bounds, now: now, candidate: candidate,
                remainingRest: snapshot.remainingRest, state: state
            )
            switch preview {
            case let .feasible(worked, _) where worked.lowerBound == worked.upperBound:
                break
            default:
                guard warningAcknowledged else { throw WorkdayError.confirmationRequired }
            }
        }
        guard desiredDepartures[dayID] != candidate else { return }
        guard revision < UInt64.max else { throw WorkdayError.revisionOverflow }
        revision += 1
        day.revision = revision
        desiredDepartures[dayID] = candidate
        days[days.count - 1] = day
    }
}

public struct ReviewVersion: Sendable, Equatable {
    public let revision: UInt64
    public let observationGeneration: UInt64
}

public struct WorkdayReviewAudit: Sendable, Equatable {
    public let dayID: UUID
    public let revision: UInt64
    public let observationGeneration: UInt64
    public let review: HistoryReviewResult
}

public enum CatalogReviewError: Error, Equatable {
    case unknownDay, inactiveDay, staleObservation, generationOverflow, changedPreview
}

public struct CatalogReviewPreview: Sendable, Equatable {
    public let dayID: UUID
    public let version: ReviewVersion
    public let review: HistoryReviewResult
}

public extension WorkdayCatalog {
    var reviewVersion: ReviewVersion {
        .init(revision: revision, observationGeneration: observationGeneration)
    }

    func snapshot(dayID: UUID, now: Int64) throws -> TimelineSnapshot {
        guard let day = days.first(where: { $0.id == dayID }) else {
            throw CatalogReviewError.unknownDay
        }
        return try day.snapshot(now: now, uncertainty: observations[dayID] ?? [])
    }

    mutating func recordObservation(
        dayID: UUID, gap: ObservationGap, now: Int64, expected: ReviewVersion
    ) throws {
        try checkVersion(expected)
        guard activeID == dayID else { throw CatalogReviewError.inactiveDay }
        guard gap.start < gap.end, gap.end <= now else { throw WorktimeError.invalidInterval }
        guard let day = days.last else { throw CatalogReviewError.unknownDay }
        var pieces = [gap]
        for audit in reviewAudit where audit.dayID == dayID {
            pieces = pieces.flatMap { Self.subtract(audit.review.selection, from: $0) }
        }
        let existing = observations[dayID] ?? []
        let next = Self.union(existing + pieces)
        _ = try day.snapshot(now: now, uncertainty: next)
        guard next != Self.union(existing) else { return }
        guard observationGeneration < UInt64.max else { throw CatalogReviewError.generationOverflow }
        observations[dayID] = next
        observationGeneration += 1
    }

    func previewReview(
        dayID: UUID, selection: ObservationGap, classification: ReviewClassification,
        now: Int64
    ) throws -> CatalogReviewPreview {
        guard let day = days.first(where: { $0.id == dayID }) else {
            throw CatalogReviewError.unknownDay
        }
        _ = try snapshot(dayID: dayID, now: now)
        let result = try HistoryReview.resolve(
            intervals: day.intervals, uncertainty: observations[dayID] ?? [],
            selection: selection, classification: classification, now: now
        )
        return CatalogReviewPreview(dayID: dayID, version: reviewVersion, review: result)
    }

    mutating func commitReview(_ preview: CatalogReviewPreview, now: Int64) throws {
        try checkVersion(preview.version)
        guard now >= preview.review.reviewedAt else { throw WorkdayError.invalidEventTime }
        guard revision < UInt64.max else { throw WorkdayError.revisionOverflow }
        guard observationGeneration < UInt64.max else { throw CatalogReviewError.generationOverflow }
        guard let index = days.firstIndex(where: { $0.id == preview.dayID }) else {
            throw CatalogReviewError.unknownDay
        }
        let fresh = try previewReview(
            dayID: preview.dayID, selection: preview.review.selection,
            classification: preview.review.classification, now: now
        ).review
        guard fresh.beforeIntervals == preview.review.beforeIntervals,
              fresh.beforeUncertainty == preview.review.beforeUncertainty,
              fresh.afterIntervals == preview.review.afterIntervals,
              fresh.afterUncertainty == preview.review.afterUncertainty
        else {
            throw CatalogReviewError.changedPreview
        }
        let old = days[index]
        let nextDay = Workday(id: old.id, profile: old.profile, state: old.state,
                              intervals: fresh.afterIntervals, revision: revision + 1,
                              futureRestPlan: old.futureRestPlan)
        _ = try nextDay.snapshot(now: now, uncertainty: fresh.afterUncertainty)
        let audit = WorkdayReviewAudit(dayID: old.id, revision: revision + 1,
                                       observationGeneration: observationGeneration + 1, review: fresh)
        days[index] = nextDay
        observations[old.id] = fresh.afterUncertainty
        reviewAudit.append(audit)
        revision += 1
        observationGeneration += 1
    }

    private func checkVersion(_ expected: ReviewVersion) throws {
        guard expected.revision == revision else { throw WorkdayError.staleRevision }
        guard expected.observationGeneration == observationGeneration else {
            throw CatalogReviewError.staleObservation
        }
    }

    private static func subtract(_ resolved: ObservationGap, from gap: ObservationGap) -> [ObservationGap] {
        guard resolved.start < gap.end, resolved.end > gap.start else { return [gap] }
        var pieces: [ObservationGap] = []
        if gap.start < resolved.start {
            pieces.append(.init(start: gap.start, end: resolved.start))
        }
        if gap.end > resolved.end {
            pieces.append(.init(start: resolved.end, end: gap.end))
        }
        return pieces
    }

    private static func union(_ gaps: [ObservationGap]) -> [ObservationGap] {
        var result: [ObservationGap] = []
        for gap in gaps.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, gap.start <= last.end {
                result[result.count - 1] = .init(start: last.start, end: max(last.end, gap.end))
            } else {
                result.append(gap)
            }
        }
        return result
    }
}
