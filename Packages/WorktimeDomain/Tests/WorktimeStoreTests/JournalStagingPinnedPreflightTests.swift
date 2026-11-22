import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingPinnedPreflightTests {
    private func withCandidate(_ body: (URL, URL, JournalStagingCandidate, UUID) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
        let first = try repo.load(now: 90)
        let dayID = UUID()
        _ = try repo.apply(
            .clockIn(id: dayID, profile: WorkdayProfile()), at: 100, now: 100, expected: first.version
        )
        let candidate = try JournalStagingDatabase.createFromPreservedSource(
            at: sourceURL, in: root, now: 110
        )
        try body(root, sourceURL, candidate, dayID)
    }

    @Test func `unchanged row bytes pass pinned preflight after appending event`() throws {
        try withCandidate { _, sourceURL, candidate, id in
            let first = try JournalStagingDatabase.preflightPinnedCandidate(
                sourceURL: sourceURL, candidate: candidate, now: 110
            )
            #expect(first.rows == candidate.draft.rows)
            let event = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            let after = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                event, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 130
            )
            let verified = try JournalStagingDatabase.preflightPinnedCandidate(
                sourceURL: sourceURL, candidate: candidate, now: 130
            )
            #expect(verified.version == after.version)
            #expect(verified.rows == after.rows)
            #expect(Array(verified.rows.prefix(first.rows.count)) == first.rows)
        }
    }

    @Test func `valid JSON whitespace mutation is rejected by exact row fence`() throws {
        try withCandidate { _, sourceURL, candidate, id in
            let sourceBytes = try Data(contentsOf: sourceURL)
            var db: OpaquePointer?
            let opened = sqlite3_open_v2(candidate.url.path, &db, SQLITE_OPEN_READWRITE, nil)
            try #require(opened == SQLITE_OK)
            let sql = "UPDATE journal_event SET payload = CAST(' ' || CAST(payload AS TEXT) AS BLOB) WHERE sequence = 1"
            let changed = sqlite3_exec(db, sql, nil, nil, nil)
            _ = sqlite3_close(db)
            try #require(changed == SQLITE_OK)
            let altered = try Data(contentsOf: candidate.url)
            let inspected = try JournalStagingDatabase.inspect(candidate.url, now: 130)
            #expect(inspected.catalog.activeID == id)
            #expect(inspected.rows != candidate.draft.rows)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.preflightPinnedCandidate(
                    sourceURL: sourceURL, candidate: candidate, now: 130
                )
            }
            let event = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.appendOfflineFromPreservedSource(
                    event, sourceURL: sourceURL, candidate: candidate,
                    expected: inspected.version, now: 130
                )
            }
            #expect(try Data(contentsOf: candidate.url) == altered)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        }
    }

    @Test func `snapshot only candidate cannot pass pinned source validation`() throws {
        try withCandidate { root, sourceURL, candidate, _ in
            let plain = try JournalStagingDatabase.create(
                source: candidate.draft.source, in: root, now: 110
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.preflightPinnedCandidate(
                    sourceURL: sourceURL, candidate: plain, now: 120
                )
            }
        }
    }
}
