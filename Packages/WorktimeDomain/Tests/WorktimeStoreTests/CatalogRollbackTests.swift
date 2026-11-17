import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CatalogRollbackTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("live.sqlite")
        try body(root, CatalogRepository(url: url, createIfMissing: true))
    }

    private func endedDay(_ repo: CatalogRepository, at: Int64, expected: StoreVersion) throws -> CatalogSession {
        let command = try WorkdayCommand.clockIn(id: UUID(), profile: WorkdayProfile())
        let started = try repo.apply(command, at: at, now: at, expected: expected)
        return try repo.apply(.clockOut(confirmBreak: false), at: at + 10, now: at + 10, expected: started.version)
    }

    @Test func `rollback preserves original journal and invalidates old generation`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let first = try endedDay(repo, at: 100, expected: initial.version)
            let bytes = try repo.makeBackup(now: 110, expected: first.version)
            let current = try endedDay(repo, at: 200, expected: first.version)
            let proposal = try repo.previewRollback(from: bytes, now: 220, expected: current.version)
            #expect(proposal.currentDays == 2)
            #expect(proposal.restoredDays == 1)
            #expect(try repo.load(now: 220).version == current.version)
            let destination = root.appendingPathComponent("preserved.json")
            let result = try repo.commitRollback(proposal, preserveCurrentAt: destination, now: 220)
            #expect(result.catalog == first.catalog)
            #expect(result.version.revision == first.version.revision)
            #expect(result.version.epoch != current.version.epoch)
            #expect(try repo.load(now: 220).version == result.version)
            let original = try CatalogBackup.inspectFile(at: destination, now: 220)
            #expect(original.catalog == current.catalog)
            #expect(original.version == current.version)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitRollback(proposal, preserveCurrentAt: root.appendingPathComponent("again"), now: 220)
            }
            #expect(throws: CatalogRollbackError.differentGeneration) {
                try repo.previewRollback(from: bytes, now: 220, expected: result.version)
            }
        }
    }

    @Test func `failed preservation leaves live data unchanged`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let first = try endedDay(repo, at: 100, expected: initial.version)
            let bytes = try repo.makeBackup(now: 110, expected: first.version)
            let current = try endedDay(repo, at: 200, expected: first.version)
            let proposal = try repo.previewRollback(from: bytes, now: 220, expected: current.version)
            let destination = root.appendingPathComponent("existing.json")
            try Data([1]).write(to: destination)
            #expect(throws: BackupFileError.self) {
                try repo.commitRollback(proposal, preserveCurrentAt: destination, now: 220)
            }
            #expect(try Data(contentsOf: destination) == Data([1]))
            #expect(try repo.load(now: 220).version == current.version)
        }
    }

    @Test func `stale confirmation cannot preserve or overwrite current data`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let first = try endedDay(repo, at: 100, expected: initial.version)
            let bytes = try repo.makeBackup(now: 110, expected: first.version)
            let second = try endedDay(repo, at: 200, expected: first.version)
            let proposal = try repo.previewRollback(from: bytes, now: 220, expected: second.version)
            let third = try endedDay(repo, at: 300, expected: second.version)
            let destination = root.appendingPathComponent("preserved.json")
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitRollback(proposal, preserveCurrentAt: destination, now: 320)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try repo.load(now: 320).version == third.version)
        }
    }

    @Test func `active work and deleted generation are rejected`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let first = try endedDay(repo, at: 100, expected: initial.version)
            let bytes = try repo.makeBackup(now: 110, expected: first.version)
            let command = try WorkdayCommand.clockIn(id: UUID(), profile: WorkdayProfile())
            let active = try repo.apply(command, at: 200, now: 200, expected: first.version)
            #expect(throws: CatalogRollbackError.activeWorkday) {
                try repo.previewRollback(from: bytes, now: 220, expected: active.version)
            }
            let store = try SnapshotStore(url: root.appendingPathComponent("live.sqlite"))
            let reset = try store.reset(expected: active.version)
            #expect(throws: CatalogRollbackError.differentGeneration) {
                try repo.previewRollback(from: bytes, now: 220, expected: reset)
            }
        }
    }

    @Test func `active backup cannot replace an ended catalog`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let command = try WorkdayCommand.clockIn(id: UUID(), profile: WorkdayProfile())
            let active = try repo.apply(command, at: 100, now: 100, expected: initial.version)
            let bytes = try repo.makeBackup(now: 100, expected: active.version)
            let current = try repo.apply(.clockOut(confirmBreak: false), at: 110, now: 110, expected: active.version)
            let store = try SnapshotStore(url: root.appendingPathComponent("live.sqlite"))
            let before = try store.load()
            #expect(throws: CatalogRollbackError.activeWorkday) {
                try repo.previewRollback(from: bytes, now: 110, expected: current.version)
            }
            #expect(try store.load() == before)
        }
    }

    @Test func `same epoch alone does not authorize divergent history`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let first = try endedDay(repo, at: 100, expected: initial.version)
            let current = try endedDay(repo, at: 200, expected: first.version)
            let store = try SnapshotStore(url: root.appendingPathComponent("live.sqlite"))
            let before = try store.load()
            let foreignURL = root.appendingPathComponent("other.sqlite")
            let foreign = try CatalogRepository(url: foreignURL, createIfMissing: true)
            let foreignInitial = try foreign.load(now: 50)
            let foreignDay = try endedDay(foreign, at: 50, expected: foreignInitial.version)
            let foreignSnapshot = try SnapshotStore(url: foreignURL).load()
            let disguised = StoredSnapshot(
                version: StoreVersion(epoch: current.version.epoch, revision: foreignDay.version.revision),
                payload: foreignSnapshot.payload
            )
            let bytes = try CatalogBackup.encode(disguised, now: 220)
            #expect(throws: CatalogRollbackError.divergentHistory) {
                try repo.previewRollback(from: bytes, now: 220, expected: current.version)
            }
            #expect(try store.load() == before)
        }
    }

    @Test func `current revision is not an earlier rollback target`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let current = try endedDay(repo, at: 100, expected: initial.version)
            let bytes = try repo.makeBackup(now: 110, expected: current.version)
            let store = try SnapshotStore(url: root.appendingPathComponent("live.sqlite"))
            let before = try store.load()
            #expect(throws: CatalogRollbackError.notEarlier) {
                try repo.previewRollback(from: bytes, now: 110, expected: current.version)
            }
            #expect(try store.load() == before)
        }
    }
}
