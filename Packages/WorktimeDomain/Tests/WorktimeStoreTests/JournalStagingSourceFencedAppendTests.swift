import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingSourceFencedAppendTests {
    private func withSource(
        _ body: (URL, URL, CatalogSession, UUID, CatalogRepository) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
        let initial = try repo.load(now: 90)
        let id = UUID()
        let active = try repo.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
        )
        try body(root, sourceURL, active, id, repo)
    }

    @Test func `anchored append preserves the source and survives independent reopen`() throws {
        try withSource { root, sourceURL, active, id, repo in
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidate = try JournalStagingDatabase.createFromPreservedSource(
                at: sourceURL, in: root, now: 110
            )
            let observed = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            let saved = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observed, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 125
            )
            #expect(saved.version.revision == active.version.revision + 1)
            #expect(saved.checkpointAnchor == .absent)
            let exit = JournalEvent(action: .command(.clockOut(confirmBreak: false), at: 130), now: 130)
            let ended = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                exit, sourceURL: sourceURL, candidate: candidate, expected: saved.version, now: 135
            )
            #expect(ended.catalog.activeID == nil)
            #expect(ended.catalog.observations[id] == [.init(start: 110, end: 120)])
            let after = try JournalStagingDatabase.inspect(candidate.url, now: 140)
            #expect(after.version == ended.version)
            #expect(after.catalog == ended.catalog)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try repo.load(now: 140).version == active.version)
        }
    }

    @Test func `checkpoint update after staging rejects append without candidate mutation`() throws {
        try withSource { root, sourceURL, active, id, _ in
            let store = try SnapshotStore(url: sourceURL)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: active.version)
            let candidate = try JournalStagingDatabase.createFromPreservedSource(
                at: sourceURL, in: root, now: 110
            )
            let before = try Data(contentsOf: candidate.url)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 120, expected: active.version)
            let event = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.appendOfflineFromPreservedSource(
                    event, sourceURL: sourceURL, candidate: candidate,
                    expected: candidate.draft.candidateVersion, now: 130
                )
            }
            #expect(try Data(contentsOf: candidate.url) == before)
        }
    }

    @Test func `unbound candidate is never accepted for source fenced appends`() throws {
        try withSource { root, sourceURL, active, id, _ in
            let candidate = try JournalStagingDatabase.create(
                source: active.validatedSnapshot, in: root, now: 110
            )
            let before = try Data(contentsOf: candidate.url)
            let event = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.appendOfflineFromPreservedSource(
                    event, sourceURL: sourceURL, candidate: candidate,
                    expected: candidate.draft.candidateVersion, now: 130
                )
            }
            #expect(try Data(contentsOf: candidate.url) == before)
        }
    }

    @Test func `source journal mutation fences old offline candidate`() throws {
        try withSource { root, sourceURL, active, id, repo in
            let candidate = try JournalStagingDatabase.createFromPreservedSource(
                at: sourceURL, in: root, now: 110
            )
            _ = try repo.apply(.clockOut(confirmBreak: false), at: 130, now: 130, expected: active.version)
            let before = try Data(contentsOf: candidate.url)
            let event = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.appendOfflineFromPreservedSource(
                    event, sourceURL: sourceURL, candidate: candidate,
                    expected: candidate.draft.candidateVersion, now: 140
                )
            }
            #expect(try Data(contentsOf: candidate.url) == before)
        }
    }

    @Test func `identical source bytes with replaced inode cannot append to old staging`() throws {
        try withSource { root, sourceURL, active, id, _ in
            let candidate = try JournalStagingDatabase.createFromPreservedSource(
                at: sourceURL, in: root, now: 110
            )
            let candidateBytes = try Data(contentsOf: candidate.url)
            let originalBytes = try Data(contentsOf: sourceURL)
            let copy = root.appendingPathComponent("replacement.sqlite")
            try FileManager.default.copyItem(at: sourceURL, to: copy)
            try FileManager.default.removeItem(at: sourceURL)
            try FileManager.default.moveItem(at: copy, to: sourceURL)
            let newBytes = try Data(contentsOf: sourceURL)
            #expect(newBytes == originalBytes)
            let event = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try JournalStagingDatabase.appendOfflineFromPreservedSource(
                    event, sourceURL: sourceURL, candidate: candidate,
                    expected: candidate.draft.candidateVersion, now: 130
                )
            }
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
            #expect(active.version == candidate.draft.source.version)
        }
    }

    @Test func `identical candidate bytes with replaced inode cannot accept new events`() throws {
        try withSource { _, sourceURL, active, id, _ in
            let root = sourceURL.deletingLastPathComponent()
            let candidate = try JournalStagingDatabase.createFromPreservedSource(
                at: sourceURL, in: root, now: 110
            )
            let previous = try Data(contentsOf: candidate.url)
            let sourceBefore = try Data(contentsOf: sourceURL)
            let copied = candidate.url.deletingLastPathComponent()
                .appendingPathComponent("candidate-copy.sqlite")
            try FileManager.default.copyItem(at: candidate.url, to: copied)
            try FileManager.default.removeItem(at: candidate.url)
            try FileManager.default.moveItem(at: copied, to: candidate.url)
            #expect(try Data(contentsOf: candidate.url) == previous)
            let event = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try JournalStagingDatabase.appendOfflineFromPreservedSource(
                    event, sourceURL: sourceURL, candidate: candidate,
                    expected: candidate.draft.candidateVersion, now: 130
                )
            }
            #expect(try Data(contentsOf: candidate.url) == previous)
            #expect(try Data(contentsOf: sourceURL) == sourceBefore)
            #expect(active.version == candidate.draft.source.version)
        }
    }
}
