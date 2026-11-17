import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct BackupInspectionTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(root, CatalogRepository(url: url, createIfMissing: true))
    }

    @Test func `inspection describes active history and leaves live store unchanged`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let day = UUID()
            let profile = try WorkdayProfile()
            let started = try repo.apply(.clockIn(id: day, profile: profile), at: 100,
                                         now: 100, expected: initial.version)
            let backup = root.appendingPathComponent("backup.json")
            try repo.writeBackup(to: backup, now: 120, expected: started.version)
            let before = try repo.load(now: 120)
            let result = try BackupInspection(file: backup, now: 120)
            #expect(result.days == 1)
            #expect(result.corrections == 0)
            #expect(result.revision == started.version.revision)
            #expect(result.hasActiveDay)
            #expect(result.firstStart == 100)
            #expect(result.lastStart == 100)
            #expect(try repo.load(now: 120).version == before.version)
            #expect(try repo.load(now: 120).catalog == before.catalog)
        }
    }

    @Test func `inspection works without a live database and empty history has no start date`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let backup = root.appendingPathComponent("empty.json")
            try repo.writeBackup(to: backup, now: 100, expected: initial.version)
            try FileManager.default.removeItem(at: root.appendingPathComponent("worktime.sqlite"))
            let result = try BackupInspection(file: backup, now: 100)
            #expect(result.days == 0)
            #expect(result.revision == 0)
            #expect(!result.hasActiveDay)
            #expect(result.firstStart == nil)
            #expect(result.lastStart == nil)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("worktime.sqlite").path))
        }
    }

    @Test func `malformed archive cannot produce a summary`() throws {
        try withRepository { root, _ in
            let backup = root.appendingPathComponent("broken.json")
            try Data([1]).write(to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            #expect(throws: CatalogBackupError.invalidArchive) {
                try BackupInspection(file: backup, now: 100)
            }
        }
    }
}
