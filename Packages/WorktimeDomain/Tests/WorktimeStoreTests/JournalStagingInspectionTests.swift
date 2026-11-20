import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingInspectionTests {
    private func withCandidate(_ body: (JournalStagingCandidate) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let command = JournalCommand.clockIn(id: UUID(), target: 25200, expectedRest: 3600)
        let journal = CatalogJournal(events: [.init(action: .command(command, at: 100), now: 100)])
        let payload = try JSONEncoder().encode(journal)
        let source = StoredSnapshot(version: .init(epoch: UUID(), revision: 1), payload: payload)
        let candidate = try JournalStagingDatabase.create(source: source, in: root, now: 130)
        try body(candidate)
    }

    @Test func `offline inspection preserves identity and exact source without draft input`() throws {
        try withCandidate { candidate in
            let original = try Data(contentsOf: candidate.url)
            let inspection = try JournalStagingDatabase.inspect(candidate.url, now: 140)
            #expect(inspection.source == candidate.draft.source)
            #expect(inspection.version == candidate.draft.candidateVersion)
            #expect(inspection.rows == candidate.draft.rows)
            let expected = try CatalogBackup.validateSnapshot(inspection.source, now: 140)
            #expect(inspection.catalog == expected.catalog)
            #expect(try Data(contentsOf: candidate.url) == original)
        }
    }

    @Test func `different valid event is rejected even if source metadata is unchanged`() throws {
        try withCandidate { candidate in
            let command = JournalCommand.clockIn(id: UUID(), target: 25200, expectedRest: 3600)
            let row = try JournalRowCodec.encode(.init(action: .command(command, at: 100), now: 100), sequence: 1)
            let hex = row.payload.map { String(format: "%02x", $0) }.joined()
            var db: OpaquePointer?
            let status = sqlite3_open_v2(candidate.url.path, &db, SQLITE_OPEN_READWRITE, nil)
            defer { sqlite3_close(db) }
            try #require(status == SQLITE_OK)
            let sql = "UPDATE journal_event SET payload = x'\(hex)' WHERE sequence = 1"
            try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
            let before = try Data(contentsOf: candidate.url)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.inspect(candidate.url, now: 140)
            }
            #expect(try Data(contentsOf: candidate.url) == before)
        }
    }

    @Test func `empty candidate can be independently reopened without creating live data`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = StoredSnapshot(version: .init(epoch: UUID(), revision: 0), payload: nil)
        let candidate = try JournalStagingDatabase.create(source: empty, in: root, now: 130)
        let inspected = try JournalStagingDatabase.inspect(candidate.url, now: 140)
        #expect(inspected.source == empty)
        #expect(inspected.version == candidate.draft.candidateVersion)
        #expect(inspected.rows.isEmpty)
        #expect(inspected.catalog == WorkdayCatalog())
    }
}
