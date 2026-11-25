import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

private enum RollbackInjectedFailure: Error {
    case beforeCommit
}

struct JournalV2RollbackTests {
    private func fixture(
        _ body: (URL, URL, JournalV2Repository) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("live")
        let preserve = root.appendingPathComponent("preserve")
        for directory in [root, live, preserve] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let database = live.appendingPathComponent("worktime.sqlite")
        try body(database, preserve, JournalV2Repository(url: database, createIfMissing: true))
    }

    private func endedDay(
        _ repository: JournalV2Repository, starting at: Int64, matching session: JournalV2Session
    ) throws -> JournalV2Session {
        let started = try repository.apply(
            .clockIn(id: UUID(), profile: WorkdayProfile()),
            at: at, now: at, matching: session
        )
        return try repository.apply(
            .clockOut(confirmBreak: false), at: at + 10, now: at + 10, matching: started
        )
    }

    @Test func `older schema two prefix restores with new epoch and preserved current journal`() throws {
        try fixture { database, preserve, repository in
            let first = try endedDay(repository, starting: 100, matching: repository.load(now: 100))
            let olderArchive = try repository.makeBackup(now: 120, matching: first)
            let latest = try endedDay(repository, starting: 200, matching: first)
            let originalArchive = try repository.makeBackup(now: 220, matching: latest)
            let proposal = try repository.previewRollback(from: olderArchive, now: 220, matching: latest)
            #expect(proposal.currentDays == 2)
            #expect(proposal.restoredDays == 1)
            #expect(proposal.currentVersion == latest.version)
            #expect(proposal.sourceVersion == first.version)

            let destination = preserve.appendingPathComponent("current.json")
            let restored = try repository.commitRollback(
                proposal, preserveCurrentAt: destination, now: 230
            )
            let copied = try BackupFile.load(destination)
            #expect(copied == originalArchive)
            #expect(try JournalV2Backup.inspect(copied, now: 230).version == latest.version)
            #expect(restored.version.epoch != latest.version.epoch)
            #expect(restored.version.revision == first.version.revision)
            #expect(restored.catalog == first.catalog)
            #expect(restored.checkpoint == nil)

            let reopened = try JournalV2Repository(url: database).load(now: 240)
            #expect(reopened.version == restored.version)
            #expect(reopened.catalog == restored.catalog)
            #expect(reopened.checkpoint == nil)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repository.makeBackup(now: 240, matching: latest)
            }
        }
    }

    @Test func `preview and failure to preserve never replace the current journal`() throws {
        try fixture { _, preserve, repository in
            let first = try endedDay(repository, starting: 100, matching: repository.load(now: 100))
            let archive = try repository.makeBackup(now: 120, matching: first)
            let latest = try endedDay(repository, starting: 200, matching: first)
            let preview = try repository.previewRollback(from: archive, now: 220, matching: latest)
            #expect(try repository.load(now: 220).version == latest.version)
            let occupied = preserve.appendingPathComponent("existing.json")
            try Data("occupied".utf8).write(to: occupied)
            #expect(throws: BackupFileError.self) {
                try repository.commitRollback(preview, preserveCurrentAt: occupied, now: 230)
            }
            #expect(try repository.load(now: 230).version == latest.version)
            #expect(try Data(contentsOf: occupied) == Data("occupied".utf8))
        }
    }

    @Test func `stale preview and erased epoch cannot authorize rollback`() throws {
        try fixture { _, preserve, repository in
            let first = try endedDay(repository, starting: 100, matching: repository.load(now: 100))
            let archive = try repository.makeBackup(now: 120, matching: first)
            let second = try endedDay(repository, starting: 200, matching: first)
            let preview = try repository.previewRollback(from: archive, now: 220, matching: second)
            let third = try endedDay(repository, starting: 300, matching: second)
            let target = preserve.appendingPathComponent("stale.json")
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repository.commitRollback(preview, preserveCurrentAt: target, now: 330)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
            let reset = try repository.commitReset(
                repository.previewReset(now: 330, matching: third), now: 331
            )
            #expect(throws: CatalogRollbackError.differentGeneration) {
                try repository.previewRollback(from: archive, now: 332, matching: reset)
            }
            #expect(try repository.load(now: 332).version == reset.version)
        }
    }

    @Test func `active workday and non-earlier archives are rejected`() throws {
        try fixture { _, _, repository in
            let first = try endedDay(repository, starting: 100, matching: repository.load(now: 100))
            let older = try repository.makeBackup(now: 120, matching: first)
            #expect(throws: CatalogRollbackError.notEarlier) {
                try repository.previewRollback(from: older, now: 120, matching: first)
            }
            let active = try repository.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()),
                at: 200, now: 200, matching: first
            )
            #expect(throws: CatalogRollbackError.activeWorkday) {
                try repository.previewRollback(from: older, now: 210, matching: active)
            }
            let activeArchive = try repository.makeBackup(now: 210, matching: active)
            let finished = try repository.apply(
                .clockOut(confirmBreak: false), at: 220, now: 220, matching: active
            )
            #expect(throws: CatalogRollbackError.activeWorkday) {
                try repository.previewRollback(from: activeArchive, now: 230, matching: finished)
            }
        }
    }

    @Test func `divergent but valid archive cannot overwrite an existing generation`() throws {
        try fixture { _, _, repository in
            let id = UUID()
            let initial = try repository.load(now: 100)
            let active = try repository.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, matching: initial
            )
            let first = try repository.apply(
                .clockOut(confirmBreak: false), at: 110, now: 110, matching: active
            )
            let archive = try repository.makeBackup(now: 120, matching: first)
            let latest = try endedDay(repository, starting: 200, matching: first)

            var object = try #require(JSONSerialization.jsonObject(with: archive) as? [String: Any])
            var payloads = try #require(object["payloads"] as? [String])
            let original = try #require(Data(base64Encoded: payloads[0]))
            let raw = try #require(String(data: original, encoding: .utf8))
            #expect(raw.contains(id.uuidString))
            payloads[0] = Data(
                raw.replacingOccurrences(of: id.uuidString, with: UUID().uuidString).utf8
            ).base64EncodedString()
            object["payloads"] = payloads
            let tampered = try JSONSerialization.data(withJSONObject: object)
            _ = try JournalV2Backup.inspect(tampered, now: 240)
            #expect(throws: CatalogRollbackError.divergentHistory) {
                try repository.previewRollback(from: tampered, now: 240, matching: latest)
            }
            #expect(try repository.load(now: 240).version == latest.version)
        }
    }

    @Test func `rollback transaction abort keeps original rows epoch and checkpoint`() throws {
        try fixture { database, _, repository in
            let first = try endedDay(repository, starting: 100, matching: repository.load(now: 100))
            let archive = try repository.makeBackup(now: 120, matching: first)
            _ = try endedDay(repository, starting: 200, matching: first)
            let store = try JournalV2LiveStore(url: database)
            let current = try store.load(now: 230)
            let candidate = try JournalV2Backup.decodeValidated(archive, now: 230)
            #expect(throws: RollbackInjectedFailure.beforeCommit) {
                try store.replaceForRollback(
                    candidate, matching: current, now: 230,
                    beforeCommit: { throw RollbackInjectedFailure.beforeCommit }
                )
            }
            let unchanged = try store.load(now: 240)
            #expect(unchanged.version == current.version)
            #expect(unchanged.rows == current.rows)
            #expect(unchanged.catalog == current.catalog)
            #expect(unchanged.checkpoint == current.checkpoint)
        }
    }

    @Test func `schema two preview accepts a valid archive above the legacy file limit`() throws {
        try fixture { database, preserve, repository in
            let first = try endedDay(
                repository, starting: 100, matching: repository.load(now: 100)
            )
            let original = try repository.makeBackup(now: 120, matching: first)
            let padding = BackupFile.maxBytes + 1 - original.count
            #expect(padding > 0)
            let paddedArchive = original + Data(repeating: 0x20, count: padding)
            let selected = preserve.appendingPathComponent("selected.json")
            try BackupFile.publish(
                paddedArchive, to: selected, maxBytes: JournalV2Backup.maxBytes
            )
            #expect(throws: BackupFileError.tooLarge) {
                try BackupFile.load(selected)
            }
            let latest = try endedDay(repository, starting: 200, matching: first)
            let preview = try repository.previewRollback(
                file: selected, now: 230, matching: latest
            )
            #expect(preview.sourceVersion == first.version)
            let preserved = preserve.appendingPathComponent("current.json")
            let restored = try repository.commitRollback(
                preview, preserveCurrentAt: preserved, now: 240
            )
            #expect(restored.catalog == first.catalog)
            #expect(restored.version.epoch != first.version.epoch)
            #expect(try JournalV2Repository(url: database).load(now: 250).catalog == first.catalog)
            #expect(try JournalV2Backup.inspect(
                BackupFile.load(preserved, maxBytes: JournalV2Backup.maxBytes), now: 250
            ).version == latest.version)
        }
    }

    @Test func `preservation inside source database directory is rejected`() throws {
        try fixture { database, _, repository in
            let first = try endedDay(repository, starting: 100, matching: repository.load(now: 100))
            let archive = try repository.makeBackup(now: 120, matching: first)
            let latest = try endedDay(repository, starting: 200, matching: first)
            let preview = try repository.previewRollback(from: archive, now: 220, matching: latest)
            let forbidden = database.deletingLastPathComponent().appendingPathComponent("preserve.json")
            #expect(throws: BackupFileError.invalidDestination) {
                try repository.commitRollback(preview, preserveCurrentAt: forbidden, now: 230)
            }
            #expect(!FileManager.default.fileExists(atPath: forbidden.path))
            #expect(try repository.load(now: 230).version == latest.version)
        }
    }
}
