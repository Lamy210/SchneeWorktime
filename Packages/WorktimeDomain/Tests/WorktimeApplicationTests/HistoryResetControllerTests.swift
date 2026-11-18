import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct HistoryResetControllerTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `confirmed active reset reopens empty and rejects prior controller writes`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let id = UUID()
            _ = try controller.perform(.clockIn(id: id, profile: WorkdayProfile()), sample: sample(100))
            let reset = try controller.previewReset(sample: sample(101))
            #expect(reset.hasActiveWorkday)
            #expect(controller.isCurrent(reset))
            let backup = url.deletingLastPathComponent().appendingPathComponent("external-copy.csv")
            try Data([1, 2, 3]).write(to: backup)
            try controller.commitReset(reset, sample: sample(102))
            var reopened = try WorktimeController(url: url, sample: sample(103))
            #expect(try reopened.refresh(sample: sample(103)) == nil)
            #expect(try reopened.recentHistory(now: 103).rows.isEmpty)
            #expect(try Data(contentsOf: backup) == Data([1, 2, 3]))
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.perform(.clockOut(confirmBreak: false), sample: sample(103))
            }
            #expect(try reopened.previewReset(sample: sample(104)).version != reset.version)
        }
    }

    @Test func `stale reset and unreliable clock do not erase current history`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let initial = try controller.previewReset(sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(101))
            let current = try controller.previewReset(sample: sample(102))
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 102)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.commitReset(initial, sample: sample(102))
            }
            #expect(throws: ApplicationClockError.unreliableClock) {
                try controller.commitReset(current, sample: ClockSample(wall: 102, uptime: 150))
            }
            #expect(try repository.load(now: 102).version == before.version)
        }
    }
}
