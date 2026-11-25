import Foundation
import WorktimeDomain
import WorktimeStore

public struct WorktimeHistoryRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Int64
    public let endedAt: Int64
    public let worked: ClosedRange<Int64>
    public let rest: Int64
    public let target: Int64
    public let remaining: ClosedRange<Int64>
    public let surplus: ClosedRange<Int64>
    public let corrections: Int
}

public enum WorktimeHistoryError: Error, Equatable {
    case invalidOffset, stalePage
}

/// A bounded, read-only view of committed ended workdays, not payroll or a calendar-day aggregate.
public struct WorktimeHistory: Sendable, Equatable {
    public let version: StoreVersion
    public let loadedAt: Int64
    public let totalEndedDays: Int
    public let rows: [WorktimeHistoryRow]
    public let offset: Int
    public static let pageSize = 30

    public var previousOffset: Int? {
        offset == 0 ? nil : offset - Self.pageSize
    }

    public var nextOffset: Int? {
        offset + rows.count < totalEndedDays ? offset + Self.pageSize : nil
    }

    public init(session: CatalogSession, now: Int64, offset: Int = 0) throws {
        try self.init(catalog: session.catalog, version: session.version, now: now, offset: offset)
    }

    /// Shared projection for the schema-2 event Journal; never replays another format.
    init(catalog: WorkdayCatalog, version: StoreVersion, now: Int64, offset: Int = 0) throws {
        self.version = version
        loadedAt = now
        let ended = catalog.days.filter { $0.state == .ended }
        totalEndedDays = ended.count
        guard offset >= 0, offset.isMultiple(of: Self.pageSize),
              offset == 0 || offset < ended.count
        else { throw WorktimeHistoryError.invalidOffset }
        self.offset = offset
        let selected = ended.reversed().dropFirst(offset).prefix(Self.pageSize)
        let corrections = Dictionary(grouping: catalog.reviewAudit, by: \.dayID)
        rows = try selected.map { day in
            guard let start = day.intervals.first?.start, let end = day.intervals.last?.end else {
                throw WorkdayError.invalidEventTime
            }
            let snapshot = try day.snapshot(now: now, uncertainty: catalog.observations[day.id] ?? [])
            let worked = snapshot.bounds.lower ... snapshot.bounds.upper
            let forecast = try DailyForecast.calculate(
                worked: worked, target: day.profile.target, remainingRest: snapshot.remainingRest, now: end,
                state: .ended
            )
            return WorktimeHistoryRow(
                id: day.id, startedAt: start, endedAt: end, worked: worked,
                rest: snapshot.recordedRest, target: day.profile.target, remaining: forecast.remaining,
                surplus: forecast.surplus, corrections: corrections[day.id]?.count ?? 0
            )
        }
    }
}
