import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingTamperTests {
    private func withCandidate(_ body: (JournalStagingCandidate) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let command = JournalCommand.clockIn(id: UUID(), target: 25200, expectedRest: 3600)
        let event = JournalEvent(action: .command(command, at: 100), now: 100)
        let payload = try JSONEncoder().encode(CatalogJournal(events: [event]))
        let source = StoredSnapshot(version: .init(epoch: UUID(), revision: 1), payload: payload)
        let candidate = try JournalStagingDatabase.create(source: source, in: root, now: 130)
        try body(candidate)
    }

    private func mutate(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(db) }
        try #require(status == SQLITE_OK)
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func `reordered sequence is rejected without rewriting candidate`() throws {
        try withCandidate { candidate in
            try mutate(candidate.url, sql: "UPDATE journal_event SET sequence = 2 WHERE sequence = 1")
            let before = try Data(contentsOf: candidate.url)
            #expect(throws: JournalMigrationError.invalidSequence) {
                try JournalStagingDatabase.inspect(candidate.url, now: 140)
            }
            let after = try Data(contentsOf: candidate.url)
            #expect(after == before)
        }
    }

    @Test func `surplus event row is rejected without silent truncation`() throws {
        try withCandidate { candidate in
            let sql = """
                INSERT INTO journal_event (sequence, payload)
                SELECT 2, payload FROM journal_event WHERE sequence = 1
                """
            try mutate(candidate.url, sql: sql)
            let before = try Data(contentsOf: candidate.url)
            #expect(throws: SnapshotStoreError.self) {
                try JournalStagingDatabase.inspect(candidate.url, now: 140)
            }
            let after = try Data(contentsOf: candidate.url)
            #expect(after == before)
        }
    }

    @Test func `unsupported schema version is never accepted as schema two`() throws {
        try withCandidate { candidate in
            try mutate(candidate.url, sql: "PRAGMA user_version = 3")
            let before = try Data(contentsOf: candidate.url)
            #expect(throws: SnapshotStoreError.unsupportedSchema) {
                try JournalStagingDatabase.inspect(candidate.url, now: 140)
            }
            let after = try Data(contentsOf: candidate.url)
            #expect(after == before)
        }
    }
}
