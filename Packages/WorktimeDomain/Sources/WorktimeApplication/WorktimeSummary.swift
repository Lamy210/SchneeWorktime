import Foundation
import WorktimeDomain
import WorktimeStore

public enum WorktimeSummaryError: Error, Equatable {
    case invalidPeriod, invalidTimeZone, overflow, staleSummary
}

public enum WorktimeSummaryUnit: Sendable, Hashable {
    case day, week, month
}

public struct WorktimeSummaryPeriod: Sendable, Equatable {
    public let unit: WorktimeSummaryUnit
    public let timeZoneID: String
    public let start: Int64
    public let end: Int64

    /// Gregorian local day, Monday-start week or calendar month. The upper boundary is exclusive.
    public init(containing instant: Int64, unit: WorktimeSummaryUnit, timeZoneID: String) throws {
        guard let zone = TimeZone(identifier: timeZoneID) else { throw WorktimeSummaryError.invalidTimeZone }
        guard (-2_208_988_800 ... 253_402_300_799).contains(instant) else {
            throw WorktimeSummaryError.invalidPeriod
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let component: Calendar.Component = switch unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        let date = Date(timeIntervalSince1970: Double(instant))
        guard let interval = calendar.dateInterval(of: component, for: date),
              let lower = Int64(exactly: interval.start.timeIntervalSince1970),
              let upper = Int64(exactly: interval.end.timeIntervalSince1970),
              lower <= instant, instant < upper
        else { throw WorktimeSummaryError.invalidPeriod }
        self.unit = unit
        self.timeZoneID = timeZoneID
        start = lower
        end = upper
    }

    public func adjacent(previous: Bool) throws -> WorktimeSummaryPeriod {
        let instant = previous ? start - 1 : end
        return try WorktimeSummaryPeriod(containing: instant, unit: unit, timeZoneID: timeZoneID)
    }
}

/// One local start date, possibly containing multiple completed Workday UUIDs.
public struct WorktimeDailySummary: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let endedDays: Int
    public let worked: ClosedRange<Int64>
    public let target: Int64
}

/// Personal retrospective, not payroll, statutory overtime or flex-period settlement.
/// A completed workday belongs entirely to the period containing its first start instant.
public struct WorktimeSummary: Sendable, Equatable {
    public let version: StoreVersion
    public let loadedAt: Int64
    public let period: WorktimeSummaryPeriod
    public let endedDays: Int
    public let uncertainDays: Int
    public let worked: ClosedRange<Int64>
    public let recordedRest: Int64
    public let target: Int64
    public let dailyShortfall: ClosedRange<Int64>
    public let dailySurplus: ClosedRange<Int64>
    public let daily: [WorktimeDailySummary]

    public init(session: CatalogSession, period: WorktimeSummaryPeriod, now: Int64) throws {
        var totals = SummaryTotals()
        var grouped: [Int64: SummaryTotals] = [:]
        guard let zone = TimeZone(identifier: period.timeZoneID) else { throw WorktimeSummaryError.invalidTimeZone }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        for day in session.catalog.days where day.state == .ended {
            guard let start = day.intervals.first?.start else { throw WorkdayError.invalidEventTime }
            guard start >= period.start, start < period.end else { continue }
            let snapshot = try day.snapshot(now: now, uncertainty: session.catalog.observations[day.id] ?? [])
            let bounds = snapshot.bounds.lower ... snapshot.bounds.upper
            let forecast = try DailyForecast.calculate(
                worked: bounds, target: day.profile.target, remainingRest: snapshot.remainingRest,
                now: now, state: .ended
            )
            try totals.accumulate(bounds: bounds, rest: snapshot.recordedRest, target: day.profile.target,
                                  forecast: forecast)
            let date = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(start)))
            guard let key = Int64(exactly: date.timeIntervalSince1970) else {
                throw WorktimeSummaryError.invalidPeriod
            }
            try grouped[key, default: SummaryTotals()].accumulate(
                bounds: bounds, rest: snapshot.recordedRest, target: day.profile.target, forecast: forecast
            )
        }
        version = session.version
        loadedAt = now
        self.period = period
        endedDays = totals.endedDays
        uncertainDays = totals.uncertainDays
        worked = totals.worked
        recordedRest = totals.rest
        target = totals.target
        dailyShortfall = totals.shortfall
        dailySurplus = totals.surplus
        daily = grouped.keys.sorted().compactMap { key in
            grouped[key].map { value in
                WorktimeDailySummary(id: key, endedDays: value.endedDays, worked: value.worked, target: value.target)
            }
        }
    }
}

private struct SummaryTotals {
    var endedDays = 0
    var uncertainDays = 0
    var worked: ClosedRange<Int64> = 0 ... 0
    var rest: Int64 = 0
    var target: Int64 = 0
    var shortfall: ClosedRange<Int64> = 0 ... 0
    var surplus: ClosedRange<Int64> = 0 ... 0

    mutating func accumulate(
        bounds: ClosedRange<Int64>, rest: Int64, target: Int64, forecast: DailyForecast
    ) throws {
        endedDays += 1
        if bounds.lowerBound != bounds.upperBound {
            uncertainDays += 1
        }
        worked = try Self.sum(worked, bounds)
        self.rest = try Self.sum(self.rest, rest)
        self.target = try Self.sum(self.target, target)
        shortfall = try Self.sum(shortfall, forecast.remaining)
        surplus = try Self.sum(surplus, forecast.surplus)
    }

    private static func sum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw WorktimeSummaryError.overflow }
        return result
    }

    private static func sum(_ lhs: ClosedRange<Int64>, _ rhs: ClosedRange<Int64>) throws -> ClosedRange<Int64> {
        try sum(lhs.lowerBound, rhs.lowerBound) ... sum(lhs.upperBound, rhs.upperBound)
    }
}
