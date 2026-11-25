import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2BackupTests {
    private func fixture(
        _ body: (URL, JournalV2Repository, UUID, JournalV2Session) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("worktime.sqlite")
        let repo = try JournalV2Repository(url: db, createIfMissing: true)
        let id = UUID()
        let started = try repo.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
            matching: repo.load(now: 100), observedAt: 100
        )
        try body(root, repo, id, started)
    }

    @Test func `schema two backup round trips audited journal without changing the source`() throws {
        try fixture { root, repo, id, started in
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 120, end: 160), now: 200, matching: started
            )
            let preview = try repo.previewReview(
                dayID: id, selection: .init(start: 130, end: 150),
                classification: .rest, now: 210, matching: observed
            )
            let reviewed = try repo.commitReview(preview, now: 211)
            let before = try repo.load(now: 220)
            let data = try repo.makeBackup(now: 220, matching: reviewed)
            let inspected = try JournalV2Backup.inspect(data, now: 220)
            #expect(inspected.version == reviewed.version)
            #expect(inspected.catalog == reviewed.catalog)
            #expect(inspected.eventCount == 3)
            #expect(inspected.catalog.reviewAudit.count == 1)
            #expect(try repo.load(now: 220).version == before.version)
            let path = root.appendingPathComponent("export.json")
            try repo.writeBackup(to: path, now: 220, matching: reviewed)
            #expect(try BackupFile.load(path) == data)
            #expect(try JournalV2Backup.inspect(BackupFile.load(path), now: 220).catalog == reviewed.catalog)
        }
    }

    @Test func `checkpoint only update invalidates a stale export session`() throws {
        try fixture { _, repo, id, started in
            let updated = try repo.saveObservationCheckpoint(
                dayID: id, observedAt: 110, now: 110, matching: started
            )
            #expect(updated.version == started.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repo.makeBackup(now: 110, matching: started)
            }
            let exported = try repo.makeBackup(now: 110, matching: updated)
            let inspected = try JournalV2Backup.inspect(exported, now: 120)
            #expect(inspected.version == started.version)
            #expect(inspected.catalog == updated.catalog)
        }
    }

    @Test func `checkpoint values are not copied into a portable archive`() throws {
        try fixture { _, repo, id, started in
            let initial = try repo.makeBackup(now: 110, matching: started)
            let newObservation = try repo.saveObservationCheckpoint(
                dayID: id, observedAt: 110, now: 110, matching: started
            )
            let later = try repo.makeBackup(now: 110, matching: newObservation)
            #expect(initial == later)
            #expect(try JournalV2Backup.inspect(later, now: 110).eventCount == 1)
        }
    }

    @Test func `stale revision or reset epoch cannot authorize an export`() throws {
        try fixture { root, repo, _, started in
            let finished = try repo.apply(
                .clockOut(confirmBreak: false), at: 150, now: 150, matching: started
            )
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.writeBackup(
                    to: root.appendingPathComponent("stale.json"), now: 160, matching: started
                )
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stale.json").path))
            let cleared = try repo.commitReset(
                repo.previewReset(now: 160, matching: finished), now: 170
            )
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.makeBackup(now: 180, matching: finished)
            }
            #expect(try JournalV2Backup.inspect(repo.makeBackup(now: 180, matching: cleared), now: 180)
                .version == cleared.version)
        }
    }

    @Test func `existing archive cannot be overwritten and the live DB stays unchanged`() throws {
        try fixture { root, repo, _, started in
            let path = root.appendingPathComponent("saved.json")
            try repo.writeBackup(to: path, now: 120, matching: started)
            let original = try BackupFile.load(path)
            #expect(throws: BackupFileError.self) {
                try repo.writeBackup(to: path, now: 120, matching: started)
            }
            #expect(try BackupFile.load(path) == original)
            #expect(try repo.load(now: 120).version == started.version)
        }
    }

    @Test func `unsupported, malformed, oversized and future archives fail closed`() throws {
        try fixture { _, repo, _, started in
            let valid = try repo.makeBackup(now: 110, matching: started)
            #expect(throws: JournalV2BackupError.invalidArchive) {
                try JournalV2Backup.inspect(Data("invalid-json".utf8), now: 120)
            }
            #expect(throws: JournalV2BackupError.tooLarge) {
                try JournalV2Backup.inspect(Data(repeating: 0, count: JournalV2Backup.maxBytes + 1), now: 120)
            }
            #expect(throws: CatalogPersistenceError.futureEvent) {
                try JournalV2Backup.inspect(valid, now: 99)
            }
            var json = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            json["schemaVersion"] = 1
            let legacy = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: JournalV2BackupError.unsupportedVersion) {
                try JournalV2Backup.inspect(legacy, now: 120)
            }
            json["schemaVersion"] = 2
            json["revision"] = 2
            let inconsistent = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: JournalMigrationError.invalidSequence) {
                try JournalV2Backup.inspect(inconsistent, now: 120)
            }
            #expect(try repo.load(now: 120).version == started.version)
        }
    }

    @Test func `inspection of an empty generation cannot create records or a checkpoint`() throws {
        try fixture { _, repo, _, started in
            let reset = try repo.commitReset(
                repo.previewReset(now: 110, matching: started), now: 111
            )
            let archive = try repo.makeBackup(now: 112, matching: reset)
            let inspected = try JournalV2Backup.inspect(archive, now: 112)
            #expect(inspected.eventCount == 0)
            #expect(inspected.catalog.days.isEmpty)
            #expect(try repo.load(now: 112).checkpoint == nil)
        }
    }
}
