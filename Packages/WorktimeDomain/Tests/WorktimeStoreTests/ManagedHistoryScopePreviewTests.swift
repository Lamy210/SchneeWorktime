import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ManagedHistoryScopePreviewTests {
    private func fixture(_ body: (URL, JournalV2Repository, JournalV2Session) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let repository = try JournalV2Repository(url: url, createIfMissing: true)
        let session = try repository.apply(
            .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100,
            matching: repository.load(now: 100), observedAt: 100
        )
        try body(root, repository, session)
    }

    @Test func `preview never initializes missing or partial managed setup`() throws {
        try fixture { root, repository, session in
            let absent = try repository.previewManagedHistory(now: 101, matching: session)
            #expect(absent.state == .notInitialized)
            #expect(absent.workdays == 1)
            #expect(absent.hasActiveWorkday)
            let managed = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let ledger = root.appendingPathComponent(ManagedHistoryRegistryFile.filename)
            #expect(!FileManager.default.fileExists(atPath: managed.path))
            #expect(!FileManager.default.fileExists(atPath: ledger.path))
            try FileManager.default.createDirectory(
                at: managed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            let partial = try repository.previewManagedHistory(now: 102, matching: session)
            #expect(partial.state == .incompleteSetup)
            #expect(!FileManager.default.fileExists(atPath: ledger.path))
        }
    }

    @Test func `registered counts exclude external files and reveal unknown managed files`() throws {
        try fixture { root, repository, session in
            try ManagedHistoryBackupWriter.initializeEmpty(in: root)
            let entry = try repository.writeManagedBackup(now: 101, matching: session)
            let external = root.appendingPathComponent(entry.name)
            let bytes = Data("outside".utf8)
            try bytes.write(to: external)
            let clean = try repository.previewManagedHistory(now: 102, matching: session)
            #expect(clean.state == .inventoried)
            #expect(clean.registeredBackups == 1)
            #expect(clean.verifiedFiles == 1)
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let unknown = directory.appendingPathComponent("unknown.json")
            try bytes.write(to: unknown)
            let dirty = try repository.previewManagedHistory(now: 103, matching: session)
            #expect(dirty.state == .inconsistent)
            #expect(dirty.unregisteredFiles == 1)
            #expect(dirty.verifiedFiles == 1)
            #expect(try Data(contentsOf: external) == bytes)
            #expect(try Data(contentsOf: unknown) == bytes)
            let saved = try repository.load(now: 104)
            #expect(JournalV2Repository.sameCommittedState(saved, session))
        }
    }

    @Test func `pending marker and stale checkpoint prevent a usable preview`() throws {
        try fixture { root, repository, session in
            let marker = root.appendingPathComponent(ManagedHistoryErasureIntentFile.filename)
            try Data("malformed".utf8).write(to: marker)
            let pending = try repository.previewManagedHistory(now: 101, matching: session)
            #expect(pending.state == .pendingErasure)
            let id = try #require(session.catalog.activeID)
            let updated = try repository.saveObservationCheckpoint(
                dayID: id, observedAt: 102, now: 102, matching: session
            )
            #expect(updated.version == session.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repository.previewManagedHistory(now: 103, matching: session)
            }
            #expect(try Data(contentsOf: marker) == Data("malformed".utf8))
        }
    }
}
