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

    public init(target: Int64 = 25200, expectedRest: Int64 = 3600) throws {
        guard target > 0, expectedRest >= 0 else { throw WorkdayError.invalidProfile }
        self.target = target
        self.expectedRest = expectedRest
    }
}

public struct Workday: Sendable, Equatable {
    public let id: UUID
    public let profile: WorkdayProfile
    public let state: WorkdayState
    public let intervals: [RecordedInterval]
    public let revision: UInt64

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
            target: profile.target, expectedRest: profile.expectedRest
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
        return Workday(id: day.id, profile: day.profile, state: state, intervals: intervals, revision: revision)
    }

    private static func close(_ intervals: inout [RecordedInterval], at instant: Int64) throws {
        guard let last = intervals.last, last.end == nil else { throw WorkdayError.invalidTransition }
        guard instant >= last.start else { throw WorkdayError.invalidEventTime }
        guard instant > last.start else { throw WorkdayError.zeroLengthInterval }
        intervals[intervals.count - 1] = .init(start: last.start, end: instant, kind: last.kind)
    }
}
