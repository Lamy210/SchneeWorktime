import Foundation
import WorktimeDomain
import WorktimeStore

public struct WorktimeGlance: Sendable {
    public let day: Workday
    public let snapshot: TimelineSnapshot
    public let forecast: DailyForecast
    public let reviewableGaps: [ObservationGap]

    public init(catalog: WorkdayCatalog, now: Int64) throws {
        guard let day = catalog.days.last else { throw WorkdayError.noActiveDay }
        let snapshot = try catalog.snapshot(dayID: day.id, now: now)
        let state: PreviewState = switch day.state {
        case .working: .working
        case .onBreak: .onBreak(returnAt: nil)
        case .ended: .ended
        }
        self.day = day
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

    public var selection: ObservationGap { stored.preview.review.selection }
    public var classification: ReviewClassification { stored.preview.review.classification }
    public var observedAt: Int64 { stored.preview.review.reviewedAt }
}

/// A single-owner application session. Callers must discard the controller after clock or storage errors.
public struct WorktimeController {
    private let repository: CatalogRepository
    private var session: CatalogSession
    private var clock: ClockObservation

    public init(url: URL, createIfMissing: Bool = false, sample: ClockSample) throws {
        repository = try CatalogRepository(url: url, createIfMissing: createIfMissing)
        session = try repository.load(now: sample.wall)
        clock = ClockObservation(initial: sample)
        // No persisted observation heartbeat yet: conservatively review the open work interval on launch.
        if let day = session.catalog.days.last, day.state == .working,
           let start = day.intervals.last?.start, start < sample.wall
        {
            try record(dayID: day.id, gap: .init(start: start, end: sample.wall), now: sample.wall)
        }
    }

    public mutating func refresh(sample: ClockSample) throws -> WorktimeGlance? {
        try observe(sample)
        return try glance(now: sample.wall)
    }

    public mutating func perform(_ command: WorkdayCommand, sample: ClockSample) throws -> WorktimeGlance? {
        try observe(sample)
        session = try repository.apply(command, at: sample.wall, now: sample.wall, expected: session.version)
        return try glance(now: sample.wall)
    }

    public mutating func previewReview(
        selection: ObservationGap, classification: ReviewClassification, sample: ClockSample
    ) throws -> WorktimeReviewProposal {
        try observe(sample)
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
        session.version == proposal.stored.version && session.catalog.days.last?.id == proposal.before.day.id
    }

    public mutating func commitReview(
        _ proposal: WorktimeReviewProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        try observe(sample)
        guard isCurrent(proposal) else { throw SnapshotStoreError.staleVersion }
        session = try repository.commitReview(proposal.stored, now: sample.wall)
        return try glance(now: sample.wall)
    }

    private mutating func observe(_ sample: ClockSample) throws {
        var updated = clock
        let gap = try updated.advance(to: sample)
        if let gap, let day = session.catalog.days.last, day.state == .working,
           let start = day.intervals.last?.start
        {
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
