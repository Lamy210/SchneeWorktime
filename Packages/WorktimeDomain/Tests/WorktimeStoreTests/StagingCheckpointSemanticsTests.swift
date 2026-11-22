import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct StagingCheckpointSemanticsTests {
    private func withCandidate(
        _ body: (URL, URL, JournalStagingCandidate, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let repository = try CatalogRepository(url: sourceURL, createIfMissing: true)
        let initial = try repository.load(now: 90)
        let id = UUID()
        let started = try repository.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
        )
        try SnapshotStore(url: sourceURL).saveObservationCheckpoint(
            dayID: id, observedAt: 110, expected: started.version
        )
        let candidate = try JournalStagingDatabase.createFromPreservedSource(
            at: sourceURL, in: root, now: 120
        )
        try body(root, sourceURL, candidate, id)
    }

    private func mutateCandidate(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        try #require(status == SQLITE_OK)
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        _ = sqlite3_close(db)
        try #require(result == SQLITE_OK)
    }

    @Test func `candidate with mismatched day id is rejected although checkpoint is well formed`() throws {
        try withCandidate { _, sourceURL, candidate, _ in
            let sourceBefore = try Data(contentsOf: sourceURL)
            let changedID = UUID().uuidString
            try mutateCandidate(
                candidate.url, sql: "UPDATE source_checkpoint SET day_id = '\(changedID)' WHERE id = 1"
            )
            let candidateBefore = try Data(contentsOf: candidate.url)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.inspect(candidate.url, now: 120)
            }
            #expect(try Data(contentsOf: sourceURL) == sourceBefore)
            #expect(try Data(contentsOf: candidate.url) == candidateBefore)
        }
    }

    @Test func `checkpoint before clock in is rejected despite correct version and UUID`() throws {
        try withCandidate { _, sourceURL, candidate, _ in
            let sourceBefore = try Data(contentsOf: sourceURL)
            try mutateCandidate(
                candidate.url, sql: "UPDATE source_checkpoint SET observed_at = 90 WHERE id = 1"
            )
            let candidateBefore = try Data(contentsOf: candidate.url)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.inspect(candidate.url, now: 120)
            }
            #expect(try Data(contentsOf: sourceURL) == sourceBefore)
            #expect(try Data(contentsOf: candidate.url) == candidateBefore)
        }
    }

    @Test func `correct anchored checkpoint passes independent inspection and preflight`() throws {
        try withCandidate { _, sourceURL, candidate, id in
            let inspected = try JournalStagingDatabase.inspect(candidate.url, now: 120)
            let expected = try JournalPreservedSourceCapture.read(at: sourceURL)
            #expect(inspected.checkpointAnchor == .captured(expected.checkpoint))
            #expect(expected.checkpoint?.dayID == id)
            let preflight = try JournalStagingDatabase.preflightPreservedSource(
                at: sourceURL, candidateURL: candidate.url, now: 120
            )
            #expect(preflight.checkpointAnchor == inspected.checkpointAnchor)
            #expect(preflight.catalog == inspected.catalog)
        }
    }
}
