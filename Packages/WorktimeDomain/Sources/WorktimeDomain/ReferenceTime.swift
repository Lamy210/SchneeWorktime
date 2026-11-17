import Foundation

public enum ReferenceTimeError: Error, Equatable {
    case invalidTimeZone, invalidWallTime, unsupportedInstant, calendarFailure
}

public enum RepeatedWallTime: Sendable, Equatable, Codable {
    case earlier, later
}

public enum ReferenceResolution: Sendable, Equatable, Codable {
    case disabled, beforeStart, nonexistent
    case ambiguous(earlier: Int64, later: Int64)
    case resolved(Int64)
}

public struct ReferenceWallTime: Sendable, Equatable, Codable {
    public let hour: Int
    public let minute: Int
    public let dayOffset: Int
    public let repeatedTime: RepeatedWallTime?

    public init(
        hour: Int = 18, minute: Int = 0, dayOffset: Int = 0, repeatedTime: RepeatedWallTime? = nil
    ) throws {
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute), (0 ... 1).contains(dayOffset) else {
            throw ReferenceTimeError.invalidWallTime
        }
        self.hour = hour
        self.minute = minute
        self.dayOffset = dayOffset
        self.repeatedTime = repeatedTime
    }
}

/// Resolved against the explicitly captured timezone, not Calendar.current.
public struct ReferenceContext: Sendable, Equatable {
    public let startedAt: Int64
    public let timeZoneID: String

    public init(startedAt: Int64, timeZoneID: String) throws {
        _ = try Self.date(startedAt)
        guard TimeZone(identifier: timeZoneID) != nil else { throw ReferenceTimeError.invalidTimeZone }
        self.startedAt = startedAt
        self.timeZoneID = timeZoneID
    }

    public func resolve(_ wallTime: ReferenceWallTime?) throws -> ReferenceResolution {
        guard let wallTime else { return .disabled }
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: timeZoneID) else { throw ReferenceTimeError.invalidTimeZone }
        calendar.timeZone = zone
        let start = try Self.date(startedAt)
        let origin = calendar.startOfDay(for: start)
        guard let shifted = calendar.date(byAdding: .day, value: wallTime.dayOffset, to: origin) else {
            throw ReferenceTimeError.calendarFailure
        }
        let day = calendar.startOfDay(for: shifted)
        guard try Self.matchesCivilDay(start: start, target: day, offset: wallTime.dayOffset, calendar: calendar)
        else { return .nonexistent }
        let components = DateComponents(hour: wallTime.hour, minute: wallTime.minute, second: 0)
        let before = day.addingTimeInterval(-1)
        let firstMatch = calendar.nextDate(
            after: before, matching: components, matchingPolicy: .strict,
            repeatedTimePolicy: .first, direction: .forward
        )
        let lastMatch = calendar.nextDate(
            after: before, matching: components, matchingPolicy: .strict,
            repeatedTimePolicy: .last, direction: .forward
        )
        guard let first = firstMatch, let last = lastMatch,
              calendar.isDate(first, inSameDayAs: day), calendar.isDate(last, inSameDayAs: day)
        else { return .nonexistent }
        let earlier = try Self.instant(first)
        let later = try Self.instant(last)
        if earlier != later, wallTime.repeatedTime == nil {
            return .ambiguous(earlier: earlier, later: later)
        }
        let selected = wallTime.repeatedTime == .later ? later : earlier
        return selected < startedAt ? .beforeStart : .resolved(selected)
    }

    private static func matchesCivilDay(start: Date, target: Date, offset: Int, calendar: Calendar) throws -> Bool {
        var civil = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw ReferenceTimeError.calendarFailure }
        civil.timeZone = utc
        let fields: Set<Calendar.Component> = [.year, .month, .day]
        let components = calendar.dateComponents(fields, from: start)
        guard let nominal = civil.date(from: components),
              let expected = civil.date(byAdding: .day, value: offset, to: nominal)
        else { throw ReferenceTimeError.calendarFailure }
        return civil.dateComponents(fields, from: expected) == calendar.dateComponents(fields, from: target)
    }

    private static func date(_ instant: Int64) throws -> Date {
        // Keep calendar operations inside the supported Gregorian civil-date range (1900–9999 UTC).
        guard (-2_208_988_800 ... 253_402_300_799).contains(instant) else {
            throw ReferenceTimeError.unsupportedInstant
        }
        return Date(timeIntervalSince1970: TimeInterval(instant))
    }

    private static func instant(_ date: Date) throws -> Int64 {
        guard let seconds = Int64(exactly: date.timeIntervalSince1970) else {
            throw ReferenceTimeError.unsupportedInstant
        }
        _ = try Self.date(seconds)
        return seconds
    }
}
