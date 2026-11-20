import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingDatabaseTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func `candidate is separate and preserves legacy snapshot on independent verification`() throws {
        try withRoot { root in
            let sourceURL = root.appendingPathComponent("worktime.sqlite")
            let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
            let initial = try repo.load(now: 100)
            let id = UUID()
            let started = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 110, end: 120), now: 120, expected: started.version
            )
            let before = try Data(contentsOf: sourceURL)
            let candidate = try JournalStagingDatabase.create(
                source: observed.validatedSnapshot, in: root, now: 130
            )
            #expect(candidate.url != sourceURL)
            #expect(candidate.draft.source == observed.validatedSnapshot)
            #expect(candidate.draft.candidateVersion.epoch != observed.version.epoch)
            try JournalStagingDatabase.verify(candidate.url, draft: candidate.draft, now: 130)
            #expect(try Data(contentsOf: sourceURL) == before)
            #expect(try repo.load(now: 130).catalog == observed.catalog)
            #expect(throws: SnapshotStoreError.unsupportedSchema) {
                try SnapshotStore(url: candidate.url)
            }
        }
    }

    @Test func `candidate missing event fails independent verification without repair`() throws {
        try withRoot { root in
            let id = UUID()
            let event = JournalEvent(action: .command(.clockIn(id: id, target: 25200, expectedRest: 3600),
                                                      at: 100), now: 100)
            let payload = try JSONEncoder().encode(CatalogJournal(events: [event]))
            let source = StoredSnapshot(version: .init(epoch: UUID(), revision: 1), payload: payload)
            let candidate = try JournalStagingDatabase.create(source: source, in: root, now: 130)
            var db: OpaquePointer?
            let status = sqlite3_open_v2(candidate.url.path, &db, SQLITE_OPEN_READWRITE, nil)
            defer { sqlite3_close(db) }
            try #require(status == SQLITE_OK)
            try #require(sqlite3_exec(db, "DELETE FROM journal_event", nil, nil, nil) == SQLITE_OK)
            let before = try Data(contentsOf: candidate.url)
            #expect(throws: SnapshotStoreError.self) {
                try JournalStagingDatabase.verify(candidate.url, draft: candidate.draft, now: 130)
            }
            #expect(try Data(contentsOf: candidate.url) == before)
            #expect(candidate.draft.source == source)
        }
    }

    @Test func `invalid legacy source cannot create candidate directory`() throws {
        try withRoot { root in
            let invalid = StoredSnapshot(version: .init(epoch: UUID(), revision: 1), payload: Data([1]))
            #expect(throws: CatalogPersistenceError.invalidJournal) {
                try JournalStagingDatabase.create(source: invalid, in: root, now: 130)
            }
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(entries.isEmpty)
        }
    }
}
