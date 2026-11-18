import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct WorktimeSummaryTests {
    private func withRepository(_ body: (CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(CatalogRepository(url: root.appendingPathComponent("worktime.sqlite"), createIfMissing: true))
    }

    private func instant(_ value: String) throws -> Int64 {
        let date = try #require(ISO8601DateFormatter().date(from: value))
        return try #require(Int64(exactly: date.timeIntervalSince1970))
    }

    @Test func `local period boundaries include DST and Monday start weeks`() throws {
        let spring = try instant("2026-03-08T17:00:00Z")
        let day = try WorktimeSummaryPeriod(containing: spring, unit: .day, timeZoneID: "America/New_York")
        #expect(day.end - day.start == 23 * 3600)
        let next = try day.adjacent(previous: false)
        #expect(next.start == day.end)
        #expect(try next.adjacent(previous: true) == day)
        let fall = try instant("2026-11-01T17:00:00Z")
        let fallDay = try WorktimeSummaryPeriod(containing: fall, unit: .day, timeZoneID: "America/New_York")
        #expect(fallDay.end - fallDay.start == 25 * 3600)
        let week = try WorktimeSummaryPeriod(containing: spring, unit: .week, timeZoneID: "America/New_York")
        #expect(week.start == (try instant("2026-03-02T05:00:00Z")))
        #expect(week.end == (try instant("2026-03-09T04:00:00Z")))
        let month = try WorktimeSummaryPeriod(containing: spring, unit: .month, timeZoneID: "Asia/Tokyo")
        #expect(month.start == (try instant("2026-02-28T15:00:00Z")))
        #expect(month.end == (try instant("2026-03-31T15:00:00Z")))
        #expect(throws: WorktimeSummaryError.invalidTimeZone) {
            try WorktimeSummaryPeriod(containing: spring, unit: .day, timeZoneID: "invalid")
        }
    }

    private func ended(
        _ repository: CatalogRepository, from session: CatalogSession, start: Int64, duration: Int64,
        uncertain: Bool = false
    ) throws -> CatalogSession {
        let profile = try WorkdayProfile(target: 100, expectedRest: 0)
        let id = UUID()
        var current = try repository.apply(
            .clockIn(id: id, profile: profile), at: start, now: start, expected: session.version
        )
        if uncertain {
            current = try repository.recordObservation(
                dayID: id, gap: .init(start: start + 10, end: start + 30),
                now: start + 30, expected: current.version
            )
        }
        return try repository.apply(
            .clockOut(confirmBreak: false), at: start + duration, now: start + duration, expected: current.version
        )
    }

    @Test func `summary preserves uncertainty and independent daily over and under targets`() throws {
        try withRepository { repository in
            let period = try WorktimeSummaryPeriod(containing: 100, unit: .day, timeZoneID: "UTC")
            var session = try repository.load(now: 100)
            session = try ended(repository, from: session, start: 100, duration: 130)
            session = try ended(repository, from: session, start: 300, duration: 90, uncertain: true)
            let active = try repository.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 400, now: 400, expected: session.version
            )
            let summary = try WorktimeSummary(session: active, period: period, now: 500)
            #expect(summary.endedDays == 2)
            #expect(summary.uncertainDays == 1)
            #expect(summary.worked == 200 ... 220)
            #expect(summary.target == 200)
            #expect(summary.dailyShortfall == 10 ... 30)
            #expect(summary.dailySurplus == 30 ... 30)
            #expect(summary.recordedRest == 0)
            #expect(try repository.load(now: 500).version == active.version)
        }
    }

    @Test func `overnight work belongs to starting period and exact boundary is exclusive`() throws {
        try withRepository { repository in
            let period = try WorktimeSummaryPeriod(containing: 100, unit: .day, timeZoneID: "UTC")
            var session = try repository.load(now: 100)
            session = try ended(repository, from: session, start: period.start, duration: 10)
            session = try ended(repository, from: session, start: period.end - 30, duration: 60)
            session = try ended(repository, from: session, start: period.end + 30, duration: 20)
            let next = try WorktimeSummaryPeriod(containing: period.end, unit: .day, timeZoneID: "UTC")
            let first = try WorktimeSummary(session: session, period: period, now: period.end + 100)
            let second = try WorktimeSummary(session: session, period: next, now: period.end + 100)
            #expect(first.endedDays == 2)
            #expect(first.worked == 70 ... 70)
            #expect(second.endedDays == 1)
            #expect(second.worked == 20 ... 20)
        }
    }
}
