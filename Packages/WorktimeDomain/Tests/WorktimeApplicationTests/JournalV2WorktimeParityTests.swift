import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2WorktimeParityTests {
    private func sample(_ at: Int64) throws -> ClockSample {
        try ClockSample(wall: at, uptime: Double(at))
    }

    private func fixture(_ body: (URL, URL, JournalV2WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let controller = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        try body(url, root, controller)
    }

    private func ended(
        _ controller: inout JournalV2WorktimeController, start: Int64, profile: WorkdayProfile
    ) throws -> UUID {
        let id = UUID()
        _ = try controller.perform(.clockIn(id: id, profile: profile), sample: sample(start))
        _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(start + 5))
        return id
    }

    @Test func `history pages from the schema two committed journal are bounded and read only`() throws {
        try fixture { url, _, initial in
            var controller = initial
            let profile = try WorkdayProfile()
            var ids: [UUID] = []
            for index in 0 ..< 31 {
                try ids.append(ended(&controller, start: 100 + Int64(index) * 10, profile: profile))
            }
            let before = try JournalV2Repository(url: url).load(now: 500)
            let page = try controller.recentHistory(now: 500)
            #expect(page.totalEndedDays == 31)
            #expect(page.rows.map(\.id) == Array(ids.suffix(30).reversed()))
            #expect(page.nextOffset == 30)
            let older = try controller.recentHistory(now: 500, offset: 30, previous: page)
            #expect(older.rows.map(\.id) == [ids[0]])
            #expect(older.nextOffset == nil)
            #expect(throws: WorktimeHistoryError.stalePage) {
                try controller.recentHistory(now: 500, offset: 30)
            }
            #expect(throws: WorktimeHistoryError.invalidOffset) {
                try controller.recentHistory(now: 500, offset: 1, previous: page)
            }
            let after = try JournalV2Repository(url: url).load(now: 500)
            #expect(after.version == before.version)
            #expect(after.checkpoint == before.checkpoint)
            #expect(after.catalog == before.catalog)
        }
    }

    @Test func `history navigation rejects a stale version after a new event`() throws {
        try fixture { _, _, initial in
            var controller = initial
            let profile = try WorkdayProfile()
            _ = try ended(&controller, start: 100, profile: profile)
            let first = try controller.recentHistory(now: 110)
            _ = try ended(&controller, start: 200, profile: profile)
            #expect(!controller.isCurrent(first))
            #expect(throws: WorktimeHistoryError.stalePage) {
                try controller.recentHistory(now: 220, offset: 0, previous: first)
            }
        }
    }

    @Test func `history read fences external checkpoint edits at the same revision`() throws {
        try fixture { url, _, initial in
            var controller = initial
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 100)
            let day = try #require(before.catalog.days.last)
            _ = try repository.saveObservationCheckpoint(
                dayID: day.id, observedAt: 105, now: 105, matching: before
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try controller.recentHistory(now: 110)
            }
        }
    }

    @Test func `summary preserves uncertain time without writing observations`() throws {
        try fixture { url, _, initial in
            var controller = initial
            let profile = try WorkdayProfile(target: 100, expectedRest: 0)
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(100))
            _ = try controller.refresh(sample: sample(110))
            _ = try controller.refresh(sample: sample(150))
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(160))
            _ = try ended(&controller, start: 200, profile: profile)
            _ = try controller.refresh(sample: sample(240))
            let source = try JournalV2Repository(url: url).load(now: 250)
            let period = try WorktimeSummaryPeriod(containing: 100, unit: .day, timeZoneID: "UTC")
            let result = try controller.summary(period: period, sample: sample(250))
            #expect(result.endedDays == 2)
            #expect(result.uncertainDays == 1)
            #expect(result.worked == 25 ... 65)
            #expect(result.target == 200)
            #expect(result.daily.count == 1)
            #expect(result.daily.first?.endedDays == 2)
            #expect(try JournalV2Repository(url: url).load(now: 250).version == source.version)
            #expect(try JournalV2Repository(url: url).load(now: 250).checkpoint == source.checkpoint)
        }
    }

    @Test func `future rest is an atomic Journal and observation update and drives reminder`() throws {
        try fixture { url, _, initial in
            var controller = initial
            let startedResult = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let started = try #require(startedResult)
            let changedResult = try controller.setFutureRest(
                minutes: 30, expectedDay: started.day, sample: sample(101)
            )
            let changed = try #require(changedResult)
            #expect(changed.day.intervals == started.day.intervals)
            #expect(changed.snapshot.remainingRest == 1800)
            #expect(changed.forecast.goal == .projected(earliestGoalAt: 25300, estimatedDepartureAt: 27100))
            let state = try JournalV2Repository(url: url).load(now: 102)
            #expect(state.version == controller.version)
            #expect(state.checkpoint?.observedAt == 101)
            #expect(state.catalog.days.last == changed.day)
            let reminder = try controller.reminderState(sample: sample(102))
            #expect(reminder?.desired.map(\.trigger) == [26200])
            #expect(reminder?.epoch == controller.version.epoch)
            #expect(reminder?.revision == controller.version.revision)
            let restoredResult = try controller.setFutureRest(
                minutes: nil, expectedDay: changed.day, sample: sample(103)
            )
            let restored = try #require(restoredResult)
            #expect(restored.snapshot.remainingRest == 3600)
            let clearedAgain = try controller.setFutureRest(
                minutes: nil, expectedDay: restored.day, sample: sample(104)
            )
            #expect(clearedAgain?.day == restored.day)
        }
    }

    @Test func `future rest rejects stale day invalid minutes and missing observation`() throws {
        try fixture { url, _, initial in
            var controller = initial
            let startedResult = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let started = try #require(startedResult)
            let changedResult = try controller.setFutureRest(
                minutes: 30, expectedDay: started.day, sample: sample(101)
            )
            let changed = try #require(changedResult)
            let before = try JournalV2Repository(url: url).load(now: 102)
            #expect(throws: FutureRestChangeError.staleContext) {
                try controller.setFutureRest(minutes: 20, expectedDay: started.day, sample: sample(102))
            }
            #expect(throws: FutureRestChangeError.invalidMinutes) {
                try controller.setFutureRest(minutes: -1, expectedDay: changed.day, sample: sample(102))
            }
            #expect(throws: FutureRestChangeError.staleContext) {
                try controller.setFutureRest(minutes: 10, expectedDay: changed.day, sample: sample(200))
            }
            let after = try JournalV2Repository(url: url).load(now: 200)
            #expect(after.version == before.version)
            #expect(after.catalog == before.catalog)
            #expect(after.checkpoint == before.checkpoint)
            #expect(try controller.reminderState(sample: sample(200)) == nil)
        }
    }

    @Test func `on break rest changes do not forge a working checkpoint`() throws {
        try fixture { url, _, initial in
            var controller = initial
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let breakResult = try controller.perform(.startBreak, sample: sample(110))
            let onBreak = try #require(breakResult)
            #expect(controller.checkpoint == nil)
            let savedResult = try controller.setFutureRest(
                minutes: 45, expectedDay: onBreak.day, sample: sample(111)
            )
            let saved = try #require(savedResult)
            #expect(saved.snapshot.remainingRest == 2700)
            #expect(controller.checkpoint == nil)
            #expect(try JournalV2Repository(url: url).load(now: 112).checkpoint == nil)
            _ = try controller.perform(.endBreak, sample: sample(120))
            #expect(controller.checkpoint?.observedAt == 120)
        }
    }

    @Test func `summary CSV refuses stale views and existing export without changing live Journal`() throws {
        try fixture { url, root, initial in
            var controller = initial
            let profile = try WorkdayProfile()
            _ = try ended(&controller, start: 100, profile: profile)
            let period = try WorktimeSummaryPeriod(containing: 100, unit: .day, timeZoneID: "UTC")
            let old = try controller.summary(period: period, sample: sample(110))
            let destination = root.appendingPathComponent("summary.csv")
            try controller.writeSummaryCSV(old, to: destination, sample: sample(110))
            #expect(try !Data(contentsOf: destination).isEmpty)
            #expect(throws: BackupFileError.self) {
                try controller.writeSummaryCSV(old, to: destination, sample: sample(110))
            }
            _ = try ended(&controller, start: 200, profile: profile)
            let before = try JournalV2Repository(url: url).load(now: 220)
            let alternate = root.appendingPathComponent("stale.csv")
            #expect(throws: WorktimeSummaryError.staleSummary) {
                try controller.writeSummaryCSV(old, to: alternate, sample: sample(220))
            }
            #expect(!FileManager.default.fileExists(atPath: alternate.path))
            #expect(try JournalV2Repository(url: url).load(now: 220).version == before.version)
        }
    }
}
