import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain

struct WorkdayReferenceTests {
    @Test func `reference difference uses actual end after clock out and is independent from goal`() throws {
        let start: Int64 = 0
        let profile = try WorkdayProfile().capturingReference(
            at: start, timeZoneID: "Etc/UTC", wallTime: ReferenceWallTime(hour: 1)
        )
        var catalog = WorkdayCatalog()
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: start, now: start, expectedRevision: 0)
        let active = try WorktimeGlance(catalog: catalog, now: 3700)
        #expect(try active.referenceDifference() == 100)
        #expect(active.forecast.remaining == 21500 ... 21500)
        try catalog.apply(.clockOut(confirmBreak: false), at: 3700, now: 3700, expectedRevision: catalog.revision)
        let ended = try WorktimeGlance(catalog: catalog, now: 7200)
        #expect(try ended.referenceDifference() == 100)
    }

    @Test func `disabled reference still captures start date and timezone`() throws {
        let profile = try WorkdayProfile().capturingReference(at: 0, timeZoneID: "Asia/Tokyo", wallTime: nil)
        let reference = try #require(profile.reference)
        #expect(reference.logicalDate == "1970-01-01")
        #expect(reference.resolution == .disabled)
        #expect(try reference.difference(at: 100) == nil)
    }
}
