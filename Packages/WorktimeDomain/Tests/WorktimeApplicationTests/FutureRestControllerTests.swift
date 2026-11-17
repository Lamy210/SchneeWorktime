import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct FutureRestControllerTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `saving remaining rest changes forecast and committed reminder without changing intervals`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let started = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let before = try #require(started)
            let saved = try controller.setFutureRest(minutes: 30, expectedDay: before.day, sample: sample(101))
            let after = try #require(saved)
            #expect(after.day.intervals == before.day.intervals)
            #expect(after.snapshot.recordedRest == 0)
            #expect(after.snapshot.remainingRest == 1800)
            #expect(after.forecast.goal == .projected(earliestGoalAt: 25300, estimatedDepartureAt: 27100))
            let reminder = try controller.reminderState(sample: sample(102))
            #expect(reminder?.desired.map(\.trigger) == [26200])
            let cleared = try controller.setFutureRest(minutes: nil, expectedDay: after.day, sample: sample(103))
            #expect(cleared?.snapshot.remainingRest == 3600)
        }
    }

    @Test func `stale day invalid amount and observation gap cannot save plan`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let started = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let before = try #require(started)
            let saved = try controller.setFutureRest(minutes: 30, expectedDay: before.day, sample: sample(101))
            let current = try #require(saved)
            let store = try SnapshotStore(url: url)
            let snapshot = try store.load()
            #expect(throws: FutureRestChangeError.staleContext) {
                try controller.setFutureRest(minutes: 10, expectedDay: before.day, sample: sample(102))
            }
            #expect(throws: FutureRestChangeError.invalidMinutes) {
                try controller.setFutureRest(minutes: -1, expectedDay: current.day, sample: sample(102))
            }
            #expect(throws: FutureRestChangeError.staleContext) {
                try controller.setFutureRest(minutes: 10, expectedDay: current.day, sample: sample(200))
            }
            #expect(try store.load() == snapshot)
        }
    }
}
