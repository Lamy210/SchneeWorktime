import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct BackupExportTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func `export during review includes only committed history`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("worktime.sqlite")
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let profile = try WorkdayProfile()
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(100))
            _ = try controller.refresh(sample: sample(110))
            _ = try controller.refresh(sample: sample(140))
            let gap = ObservationGap(start: 110, end: 140)
            let proposal = try controller.previewReview(selection: gap, classification: .rest, sample: sample(141))
            let repo = try CatalogRepository(url: url)
            let before = try repo.load(now: 141)
            let backup = root.appendingPathComponent("backup.json")
            try controller.writeBackup(to: backup, now: 141)
            let candidate = try CatalogBackup.inspectFile(at: backup, now: 141)
            #expect(candidate.version == before.version)
            #expect(candidate.catalog == before.catalog)
            #expect(candidate.catalog.reviewAudit.isEmpty)
            #expect(controller.isCurrent(proposal))
            #expect(try repo.load(now: 141).catalog == before.catalog)
        }
    }

    @Test func `export from stale controller fails without producing a file`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("worktime.sqlite")
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let profile = try WorkdayProfile()
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(100))
            let repo = try CatalogRepository(url: url)
            let before = try repo.load(now: 110)
            let saved = try repo.apply(.startBreak, at: 110, now: 110, expected: before.version)
            let backup = root.appendingPathComponent("backup.json")
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.writeBackup(to: backup, now: 110)
            }
            #expect(!FileManager.default.fileExists(atPath: backup.path))
            #expect(try repo.load(now: 110).version == saved.version)
        }
    }
}
