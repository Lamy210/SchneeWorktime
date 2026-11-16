import Foundation
import Testing
@testable import WorktimeDomain

struct ReferenceTimeTests {
    private func instant(_ value: String) throws -> Int64 {
        let date = try #require(ISO8601DateFormatter().date(from: value))
        return Int64(date.timeIntervalSince1970)
    }

    @Test func `same day reference is independent of current timezone`() throws {
        let start = try instant("2026-11-17T02:30:00Z")
        let context = try ReferenceContext(startedAt: start, timeZoneID: "Asia/Tokyo")
        let result = try context.resolve(ReferenceWallTime())
        let expected = try instant("2026-11-17T09:00:00Z")
        #expect(result == .resolved(expected))
        #expect(try context.resolve(nil) == .disabled)
    }

    @Test func `next day must be explicit`() throws {
        let start = try instant("2026-11-17T12:00:00Z")
        let context = try ReferenceContext(startedAt: start, timeZoneID: "Asia/Tokyo")
        #expect(try context.resolve(ReferenceWallTime()) == .beforeStart)
        let result = try context.resolve(ReferenceWallTime(hour: 6, dayOffset: 1))
        let expected = try instant("2026-11-17T21:00:00Z")
        #expect(result == .resolved(expected))
    }

    @Test func `spring forward time is not shifted silently`() throws {
        let start = try instant("2026-03-07T18:00:00Z")
        let context = try ReferenceContext(startedAt: start, timeZoneID: "America/New_York")
        let wall = try ReferenceWallTime(hour: 2, minute: 30, dayOffset: 1)
        #expect(try context.resolve(wall) == .nonexistent)
    }

    @Test func `fall back requires explicit occurrence`() throws {
        let start = try instant("2026-10-31T17:00:00Z")
        let context = try ReferenceContext(startedAt: start, timeZoneID: "America/New_York")
        let first = try instant("2026-11-01T05:30:00Z")
        let last = try instant("2026-11-01T06:30:00Z")
        let wall = try ReferenceWallTime(hour: 1, minute: 30, dayOffset: 1)
        #expect(try context.resolve(wall) == .ambiguous(earlier: first, later: last))
        let early = try ReferenceWallTime(hour: 1, minute: 30, dayOffset: 1, repeatedTime: .earlier)
        let late = try ReferenceWallTime(hour: 1, minute: 30, dayOffset: 1, repeatedTime: .later)
        #expect(try context.resolve(early) == .resolved(first))
        #expect(try context.resolve(late) == .resolved(last))
    }

    @Test func `skipped civil day is not silently moved`() throws {
        let start = try instant("2011-12-29T22:00:00Z")
        let context = try ReferenceContext(startedAt: start, timeZoneID: "Pacific/Apia")
        let wall = try ReferenceWallTime(hour: 18, dayOffset: 1)
        #expect(try context.resolve(wall) == .nonexistent)
    }

    @Test func `invalid inputs fail closed`() throws {
        #expect(throws: ReferenceTimeError.invalidWallTime) { try ReferenceWallTime(hour: 24) }
        #expect(throws: ReferenceTimeError.invalidWallTime) { try ReferenceWallTime(dayOffset: 2) }
        #expect(throws: ReferenceTimeError.invalidTimeZone) {
            try ReferenceContext(startedAt: 0, timeZoneID: "Invalid/Zone")
        }
        #expect(throws: ReferenceTimeError.unsupportedInstant) {
            try ReferenceContext(startedAt: Int64.max, timeZoneID: "Asia/Tokyo")
        }
    }
}
