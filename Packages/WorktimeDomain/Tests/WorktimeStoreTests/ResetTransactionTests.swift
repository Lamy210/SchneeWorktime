import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ResetTransactionTests {
    private func withStore(_ body: (URL, SnapshotStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worktime.sqlite")
        try body(url, SnapshotStore(url: url, createIfMissing: true))
    }

    private func execute(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(handle) }
        guard status == SQLITE_OK, let handle else { throw SnapshotStoreError.sqlite(status) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw SnapshotStoreError.sqlite(result) }
    }

    @Test func `same version changed payload cannot pass exact snapshot reset fence`() throws {
        try withStore { url, store in
            let version = try store.save(Data([1]), expected: store.load().version)
            let confirmed = try store.load()
            try execute("UPDATE snapshot SET payload = X'02' WHERE id = 1", at: url)
            #expect(throws: CatalogPersistenceError.invalidJournal) {
                try store.reset(expected: version, matching: confirmed)
            }
            let actual = try store.load()
            #expect(actual.version == version)
            #expect(actual.payload == Data([2]))
        }
    }

    @Test func `checkpoint cleanup failure rolls back logical reset and epoch change`() throws {
        try withStore { url, store in
            let version = try store.save(Data([1]), expected: store.load().version)
            let before = try store.load()
            // DROP TABLE fails for a view of the same name, after the snapshot UPDATE has executed.
            try execute("CREATE VIEW observation_checkpoint AS SELECT 1 AS id", at: url)
            #expect(throws: SnapshotStoreError.self) {
                try store.reset(expected: version, matching: before)
            }
            #expect(try SnapshotStore(url: url).load() == before)
            try execute("DROP VIEW observation_checkpoint", at: url)
            let reset = try store.reset(expected: version, matching: before)
            #expect(reset.epoch != version.epoch)
            #expect(reset.revision == 0)
            #expect(try SnapshotStore(url: url).load().payload == nil)
        }
    }
}
