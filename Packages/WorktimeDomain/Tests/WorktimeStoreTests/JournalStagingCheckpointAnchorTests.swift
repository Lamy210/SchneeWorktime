import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingCheckpointAnchorTests {
    private func withActiveSource(
        _ body: (URL, URL, CatalogSession, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.sqlite")
        let repo = try CatalogRepository(url: url, createIfMissing: true)
        let initial = try repo.load(now: 90)
        let dayID = UUID()
        let active = try repo.apply(
            .clockIn(id: dayID, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
        )
        try body(root, url, active, dayID)
    }

    @Test func `captured checkpoint is bound and later same revision update is rejected`() throws {
        try withActiveSource { root, url, active, id in
            let store = try SnapshotStore(url: url)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: active.version)
            let before = try JournalPreservedSourceCapture.read(at: url)
            let candidate = try JournalStagingDatabase.createFromPreservedSource(
                at: url, in: root, now: 120
            )
            let inspected = try JournalStagingDatabase.inspect(candidate.url, now: 120)
            #expect(inspected.checkpointAnchor == .captured(before.checkpoint))
            #expect(inspected.source == active.validatedSnapshot)
            let savedCandidate = try Data(contentsOf: candidate.url)
            let savedSource = try Data(contentsOf: url)
            let verified = try JournalStagingDatabase.preflightPreservedSource(
                at: url, candidateURL: candidate.url, now: 120
            )
            #expect(verified.checkpointAnchor == inspected.checkpointAnchor)
            #expect(try Data(contentsOf: url) == savedSource)
            #expect(try Data(contentsOf: candidate.url) == savedCandidate)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 115, expected: active.version)
            let latest = try JournalPreservedSourceCapture.read(at: url)
            #expect(latest.snapshot == before.snapshot)
            #expect(latest.checkpoint != before.checkpoint)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.preflightPreservedSource(
                    at: url, candidateURL: candidate.url, now: 120
                )
            }
            #expect(try Data(contentsOf: candidate.url) == savedCandidate)
        }
    }

    @Test func `absent checkpoint is anchored and later insertion is rejected`() throws {
        try withActiveSource { root, url, active, id in
            let candidate = try JournalStagingDatabase.createFromPreservedSource(at: url, in: root, now: 120)
            let inspected = try JournalStagingDatabase.inspect(candidate.url, now: 120)
            #expect(inspected.checkpointAnchor == .absent)
            _ = try JournalStagingDatabase.preflightPreservedSource(
                at: url, candidateURL: candidate.url, now: 120
            )
            try SnapshotStore(url: url).saveObservationCheckpoint(
                dayID: id, observedAt: 110, expected: active.version
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.preflightPreservedSource(
                    at: url, candidateURL: candidate.url, now: 120
                )
            }
        }
    }

    @Test func `old unbound candidate remains readable but has no checkpoint guarantee`() throws {
        try withActiveSource { root, url, active, id in
            let candidate = try JournalStagingDatabase.create(
                source: active.validatedSnapshot, in: root, now: 120
            )
            let inspected = try JournalStagingDatabase.inspect(candidate.url, now: 120)
            #expect(inspected.checkpointAnchor == .unbound)
            try SnapshotStore(url: url).saveObservationCheckpoint(
                dayID: id, observedAt: 110, expected: active.version
            )
            let unbound = try JournalStagingDatabase.preflightPreservedSource(
                at: url, candidateURL: candidate.url, now: 120
            )
            #expect(unbound.checkpointAnchor == .unbound)
        }
    }

    @Test func `tampered checkpoint anchor is rejected without rewriting candidate`() throws {
        try withActiveSource { root, url, active, id in
            try SnapshotStore(url: url).saveObservationCheckpoint(
                dayID: id, observedAt: 110, expected: active.version
            )
            let candidate = try JournalStagingDatabase.createFromPreservedSource(
                at: url, in: root, now: 120
            )
            var db: OpaquePointer?
            let status = sqlite3_open_v2(candidate.url.path, &db, SQLITE_OPEN_READWRITE, nil)
            try #require(status == SQLITE_OK)
            let mutation = "UPDATE source_checkpoint SET source_revision = source_revision + 1 WHERE id = 1"
            let executed = sqlite3_exec(db, mutation, nil, nil, nil)
            _ = sqlite3_close(db)
            try #require(executed == SQLITE_OK)
            let before = try Data(contentsOf: candidate.url)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.inspect(candidate.url, now: 120)
            }
            #expect(try Data(contentsOf: candidate.url) == before)
        }
    }
}
