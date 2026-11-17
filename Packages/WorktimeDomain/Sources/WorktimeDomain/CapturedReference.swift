import Foundation

/// Capture once at explicit clock-in. Journal replay preserves the original Instant across timezone changes.
public struct CapturedReference: Sendable, Equatable, Codable {
    public let startedAt: Int64
    public let timeZoneID: String
    public let logicalDate: String
    public let wallTime: ReferenceWallTime?
    public let resolution: ReferenceResolution

    public init(startedAt: Int64, timeZoneID: String, wallTime: ReferenceWallTime?) throws {
        let context = try ReferenceContext(startedAt: startedAt, timeZoneID: timeZoneID)
        guard let zone = TimeZone(identifier: timeZoneID) else { throw ReferenceTimeError.invalidTimeZone }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = Date(timeIntervalSince1970: Double(startedAt))
        let fields = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = fields.year, let month = fields.month, let day = fields.day else {
            throw ReferenceTimeError.calendarFailure
        }
        self.startedAt = startedAt
        self.timeZoneID = timeZoneID
        logicalDate = String(format: "%04d-%02d-%02d", year, month, day)
        self.wallTime = wallTime
        resolution = try context.resolve(wallTime)
        try validate(startedAt: startedAt)
    }

    public var referenceAt: Int64? {
        guard case let .resolved(instant) = resolution else { return nil }
        return instant
    }

    /// Verify the serialized structure without resolving old wall times using today's timezone rules.
    public func validate(startedAt: Int64) throws {
        guard self.startedAt == startedAt, !timeZoneID.isEmpty, timeZoneID.utf8.count <= 255,
              logicalDate.utf8.count == 10, validInstant(startedAt)
        else { throw ReferenceTimeError.calendarFailure }
        let parts = logicalDate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1 ... 9999).contains(year), (1 ... 12).contains(month), (1 ... 31).contains(day),
              logicalDate == String(format: "%04d-%02d-%02d", year, month, day)
        else { throw ReferenceTimeError.calendarFailure }
        if let wallTime {
            _ = try ReferenceWallTime(hour: wallTime.hour, minute: wallTime.minute,
                                      dayOffset: wallTime.dayOffset, repeatedTime: wallTime.repeatedTime)
        }
        switch resolution {
        case .disabled:
            guard wallTime == nil else { throw ReferenceTimeError.invalidWallTime }
        case .beforeStart, .nonexistent:
            guard wallTime != nil else { throw ReferenceTimeError.invalidWallTime }
        case let .resolved(instant):
            guard wallTime != nil, validInstant(instant), instant >= startedAt else {
                throw ReferenceTimeError.invalidWallTime
            }
        case let .ambiguous(earlier, later):
            guard let wallTime, wallTime.repeatedTime == nil, earlier < later,
                  validInstant(earlier), validInstant(later)
            else { throw ReferenceTimeError.invalidWallTime }
        }
    }

    /// The end of a completed shift, not the current clock, is its comparison point.
    public func difference(at instant: Int64) throws -> Int64? {
        guard let referenceAt else { return nil }
        let (difference, overflow) = instant.subtractingReportingOverflow(referenceAt)
        guard !overflow else { throw WorktimeError.overflow }
        return difference
    }

    private func validInstant(_ instant: Int64) -> Bool {
        (-2_208_988_800 ... 253_402_300_799).contains(instant)
    }
}
