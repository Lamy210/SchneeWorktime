import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CatalogRevalidationTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func `unchanged committed snapshot can be reused without rewriting storage`() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("live.sqlite")
            let repository = try CatalogRepository(url: url, createIfMissing: true)
            let initial = try repository.load(now: 100)
            let command = try WorkdayCommand.clockIn(id: UUID(), profile: WorkdayProfile())
            let started = try repository.apply(command, at: 100, now: 100, expected: initial.version)
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            let checked = try repository.revalidate(started, now: 110)
            #expect(checked.catalog == started.catalog)
            #expect(checked.version == started.version)
            #expect(checked.validatedAt == started.validatedAt)
            #expect(try store.load() == before)
            #expect(throws: CatalogPersistenceError.futureEvent) {
                try repository.revalidate(started, now: 99)
            }
        }
    }

    @Test func `same version with different valid journal bytes is rejected`() throws {
        try withDirectory { directory in
            let liveURL = directory.appendingPathComponent("live.sqlite")
            let live = try CatalogRepository(url: liveURL, createIfMissing: true)
            let otherURL = directory.appendingPathComponent("other.sqlite")
            let other = try CatalogRepository(url: otherURL, createIfMissing: true)
            let initial = try live.load(now: 100)
            let otherInitial = try other.load(now: 100)
            let command = try WorkdayCommand.clockIn(id: UUID(), profile: WorkdayProfile())
            let started = try live.apply(command, at: 100, now: 100, expected: initial.version)
            let different = try other.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100, expected: otherInitial.version
            )
            let mismatched = StoredSnapshot(version: started.version, payload: different.validatedSnapshot.payload)
            let cached = try CatalogBackup.validateSnapshot(mismatched, now: 100)
            #expect(cached.version == started.version)
            #expect(cached.catalog != started.catalog)
            #expect(throws: CatalogPersistenceError.invalidJournal) {
                try live.revalidate(cached, now: 110)
            }
        }
    }

    @Test func `external revision and reset generation invalidate cached state`() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("live.sqlite")
            let repository = try CatalogRepository(url: url, createIfMissing: true)
            let initial = try repository.load(now: 100)
            let command = try WorkdayCommand.clockIn(id: UUID(), profile: WorkdayProfile())
            let started = try repository.apply(command, at: 100, now: 100, expected: initial.version)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repository.revalidate(initial, now: 101)
            }
            let store = try SnapshotStore(url: url)
            _ = try store.reset(expected: started.version)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repository.revalidate(started, now: 101)
            }
        }
    }
}
