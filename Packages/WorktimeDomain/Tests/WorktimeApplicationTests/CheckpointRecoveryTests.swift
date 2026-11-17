import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct CheckpointRecoveryTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `restart retains observed work before a committed checkpoint`() throws {
        try withDatabase { url in
            var first = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try first.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try first.refresh(sample: sample(110))
            _ = try first.refresh(sample: sample(118))
            var restored = try WorktimeController(url: url, sample: sample(200))
            let result = try restored.refresh(sample: sample(210))
            let glance = try #require(result)
            #expect(glance.reviewableGaps == [.init(start: 110, end: 200)])
            #expect(glance.snapshot.bounds.lower == 20)
            #expect(glance.snapshot.bounds.upper == 110)
            #expect(glance.forecast.goal == .uncertain)
        }
    }

    @Test func `saved polling gap survives another restart without gaining credit`() throws {
        try withDatabase { url in
            var first = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try first.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try first.refresh(sample: sample(110))
            _ = try first.refresh(sample: sample(150))
            var restored = try WorktimeController(url: url, sample: sample(200))
            let result = try restored.refresh(sample: sample(210))
            let glance = try #require(result)
            #expect(glance.snapshot.bounds.lower == 20)
            #expect(glance.snapshot.bounds.upper == 110)
            #expect(glance.reviewableGaps == [.init(start: 110, end: 200)])
        }
    }

    @Test func `legacy journal without marker still flags the full open interval`() throws {
        try withDatabase { url in
            let repo = try CatalogRepository(url: url, createIfMissing: true)
            let initial = try repo.load(now: 100)
            let command = WorkdayCommand.clockIn(id: UUID(), profile: try WorkdayProfile())
            _ = try repo.apply(command, at: 100, now: 100, expected: initial.version)
            var restored = try WorktimeController(url: url, sample: sample(200))
            let result = try restored.refresh(sample: sample(210))
            let glance = try #require(result)
            #expect(glance.reviewableGaps == [.init(start: 100, end: 200)])
            #expect(glance.snapshot.bounds.lower == 10)
        }
    }

    @Test func `future checkpoint refuses recovery instead of crediting unknown time`() throws {
        try withDatabase { url in
            var first = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try first.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try first.refresh(sample: sample(110))
            #expect(throws: ApplicationClockError.unreliableClock) {
                try WorktimeController(url: url, sample: sample(105))
            }
        }
    }

    @Test func `restart after break does not reuse the previous working revision`() throws {
        try withDatabase { url in
            var first = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try first.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try first.perform(.startBreak, sample: sample(110))
            var restored = try WorktimeController(url: url, sample: sample(200))
            let result = try restored.refresh(sample: sample(210))
            let glance = try #require(result)
            #expect(glance.snapshot.bounds.lower == 10)
            #expect(glance.snapshot.bounds.upper == 10)
            #expect(glance.reviewableGaps.isEmpty)
        }
    }
}
