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
