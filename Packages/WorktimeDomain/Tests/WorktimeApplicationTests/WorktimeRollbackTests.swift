import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct WorktimeRollbackTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func endedDay(_ controller: inout WorktimeController, at start: Int64) throws {
        _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(start))
        _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(start + 10))
    }

    @Test func `rollback preview captures file bytes and preserves later history before replacement`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("live.sqlite")
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            try endedDay(&controller, at: 100)
            let source = root.appendingPathComponent("earlier.json")
            try controller.writeBackup(to: source, now: 110)
            try endedDay(&controller, at: 200)
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 220)
            let proposal = try controller.previewRollback(file: source, sample: sample(220))
            #expect(proposal.currentDays == 2)
            #expect(proposal.restoredDays == 1)
            #expect(try repository.load(now: 220).version == before.version)
            try Data([1]).write(to: source)
            let destination = root.appendingPathComponent("preserved.json")
            try controller.commitRollback(proposal, preserveCurrentAt: destination, sample: sample(221))
            let restored = try repository.load(now: 221)
            #expect(restored.catalog.days.count == 1)
            #expect(restored.version.epoch != before.version.epoch)
            let preserved = try CatalogBackup.inspectFile(at: destination, now: 221)
            #expect(preserved.catalog == before.catalog)
            var reopened = try WorktimeController(url: url, sample: sample(222))
            let current = try reopened.refresh(sample: sample(222))
            #expect(current?.day.state == .ended)
            #expect(!reopened.isCurrent(proposal))
        }
    }

    @Test func `stale rollback is rejected without creating a preservation file`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("live.sqlite")
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            try endedDay(&controller, at: 100)
            let source = root.appendingPathComponent("earlier.json")
            try controller.writeBackup(to: source, now: 110)
            try endedDay(&controller, at: 200)
            let proposal = try controller.previewRollback(file: source, sample: sample(220))
            try endedDay(&controller, at: 230)
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 240)
            let destination = root.appendingPathComponent("preserved.json")
            #expect(!controller.isCurrent(proposal))
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.commitRollback(proposal, preserveCurrentAt: destination, sample: sample(241))
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try repository.load(now: 241).version == before.version)
        }
    }
}
