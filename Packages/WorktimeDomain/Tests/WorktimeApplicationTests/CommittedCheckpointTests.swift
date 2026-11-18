import CSQLite
import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct CommittedCheckpointTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("worktime.sqlite"))
    }

    private func execute(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(handle) }
        guard status == SQLITE_OK, let handle else { throw SnapshotStoreError.sqlite(status) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw SnapshotStoreError.sqlite(result) }
    }

    @Test func `committed clock in is distinguished from checkpoint failure and recovered once`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let id = UUID()
            try execute("CREATE VIEW observation_checkpoint AS SELECT 1 AS id", at: url)
            let repository = try CatalogRepository(url: url)
            do {
                _ = try controller.perform(.clockIn(id: id, profile: WorkdayProfile()), sample: sample(101))
                Issue.record("Expected the auxiliary checkpoint write to fail")
            } catch let error as CommittedCheckpointError {
                let saved = try repository.load(now: 101)
                #expect(saved.version == error.version)
                #expect(saved.catalog.activeID == id)
                #expect(saved.catalog.days.count == 1)
            }
            try execute("DROP VIEW observation_checkpoint", at: url)
            var reopened = try WorktimeController(url: url, sample: sample(110))
            let glance = try #require(reopened.refresh(sample: sample(110)))
            #expect(glance.day.id == id)
            #expect(glance.snapshot.bounds.lower == 0)
            #expect(glance.snapshot.bounds.upper == 9)
            #expect(try repository.load(now: 110).catalog.days.count == 1)
        }
    }
}
