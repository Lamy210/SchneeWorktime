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

/// A bounded, read-only view of committed ended workdays, not payroll or a calendar-day aggregate.
public struct WorktimeHistory: Sendable, Equatable {
    public let version: StoreVersion
    public let loadedAt: Int64
    public let totalEndedDays: Int
    public let rows: [WorktimeHistoryRow]

    public init(session: CatalogSession, now: Int64) throws {
        version = session.version
        loadedAt = now
        let ended = session.catalog.days.filter { $0.state == .ended }
        totalEndedDays = ended.count
        let selected = ended.suffix(30).reversed()
        let corrections = Dictionary(grouping: session.catalog.reviewAudit, by: \.dayID)
        rows = try selected.map { day in
            guard let start = day.intervals.first?.start, let end = day.intervals.last?.end else {
                throw WorkdayError.invalidEventTime
            }
            let snapshot = try day.snapshot(now: now, uncertainty: session.catalog.observations[day.id] ?? [])
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
