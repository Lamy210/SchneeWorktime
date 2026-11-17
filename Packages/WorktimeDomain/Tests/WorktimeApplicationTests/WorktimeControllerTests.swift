import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain

struct WorktimeControllerTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `normal observations keep verified work and forecast distinct`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let start = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            #expect(start?.forecast.goal == .projected(earliestGoalAt: 25300, estimatedDepartureAt: 28900))
            let current = try #require(controller.refresh(sample: sample(110)))
            #expect(current.snapshot.bounds.lower == 10)
            #expect(current.snapshot.bounds.upper == 10)
        }
    }

    @Test func `polling gap is recorded before clock out`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try controller.refresh(sample: sample(110))
            let ended = try #require(controller.perform(.clockOut(confirmBreak: false), sample: sample(140)))
            #expect(ended.snapshot.bounds.lower == 10)
            #expect(ended.snapshot.bounds.upper == 40)
            #expect(ended.forecast.goal == .ended)
            let later = try #require(controller.refresh(sample: sample(150)))
            #expect(later.snapshot == ended.snapshot)
        }
    }

    @Test func `reopen marks open work unverified instead of asserting attendance`() throws {
        try withDatabase { url in
            var first = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try first.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            var reopened = try WorktimeController(url: url, sample: sample(200))
            let current = try #require(reopened.refresh(sample: sample(210)))
            #expect(current.snapshot.bounds.lower == 10)
            #expect(current.snapshot.bounds.upper == 110)
            #expect(current.forecast.goal == .uncertain)
        }
    }

    @Test func `backward and divergent clocks are rejected`() throws {
        var monitor = try ClockObservation(initial: sample(100))
        #expect(throws: ApplicationClockError.unreliableClock) {
            try monitor.advance(to: sample(99))
        }
        let shifted = try ClockSample(wall: 200, uptime: 101)
        #expect(throws: ApplicationClockError.unreliableClock) {
            try monitor.advance(to: shifted)
        }
        #expect(try monitor.advance(to: sample(101)) == nil)
    }

    @Test func `break interval does not count as unverified work`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try controller.perform(.startBreak, sample: sample(110))
            let current = try #require(controller.refresh(sample: sample(200)))
            #expect(current.snapshot.bounds.lower == 10)
            #expect(current.snapshot.bounds.upper == 10)
            #expect(current.snapshot.recordedRest == 90)
            #expect(current.forecast.goal == .onBreak)
        }
    }
}
