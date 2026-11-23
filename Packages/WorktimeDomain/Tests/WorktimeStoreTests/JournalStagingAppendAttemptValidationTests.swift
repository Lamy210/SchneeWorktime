import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingAppendAttemptValidationTests {
    private func withCandidate(
        _ body: (URL, JournalStagingCandidate, UUID, StoreVersion) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
        let empty = try repo.load(now: 90)
        let id = UUID()
        let active = try repo.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: empty.version
        )
        let candidate = try JournalStagingDatabase.createFromPreservedSource(
            at: sourceURL, in: root, now: 110
        )
        try body(sourceURL, candidate, id, active.version)
    }

    @Test func `receipt rejects a retrograde event without writes`() throws {
        try withCandidate { sourceURL, candidate, id, _ in
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let retrograde = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 99
            )
            #expect(throws: JournalMigrationError.invalidEvent) {
                try JournalStagingDatabase.captureOfflineAppendAttempt(
                    retrograde, sourceURL: sourceURL, candidate: candidate,
                    expected: candidate.draft.candidateVersion, now: 130
                )
            }
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `receipt refuses invalid domain action without writes`() throws {
        try withCandidate { sourceURL, candidate, _, _ in
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let invalid = JournalEvent(
                action: .futureRest(dayID: UUID(), remainingSeconds: 60), now: 130
            )
            var rejected = false
            do {
                _ = try JournalStagingDatabase.captureOfflineAppendAttempt(
                    invalid, sourceURL: sourceURL, candidate: candidate,
                    expected: candidate.draft.candidateVersion, now: 130
                )
            } catch {
                rejected = true
            }
            #expect(rejected)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `receipt rejects stale expected revision after append`() throws {
        try withCandidate { sourceURL, candidate, id, _ in
            let original = candidate.draft.candidateVersion
            let observed = JournalEvent(
                action: .observation(dayID: id, start: 110, end: 120), now: 120
            )
            _ = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observed, sourceURL: sourceURL, candidate: candidate,
                expected: original, now: 130
            )
            let before = try Data(contentsOf: candidate.url)
            let next = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            #expect(throws: SnapshotStoreError.staleVersion) {
                try JournalStagingDatabase.captureOfflineAppendAttempt(
                    next, sourceURL: sourceURL, candidate: candidate,
                    expected: original, now: 140
                )
            }
            #expect(try Data(contentsOf: candidate.url) == before)
        }
    }

    @Test func `receipt rejects later source checkpoint change`() throws {
        try withCandidate { sourceURL, candidate, id, sourceVersion in
            let event = JournalEvent(
                action: .observation(dayID: id, start: 110, end: 120), now: 120
            )
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                event, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let before = try Data(contentsOf: candidate.url)
            let store = try SnapshotStore(url: sourceURL)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: sourceVersion)
            #expect(JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 130
            ) == .indeterminate)
            #expect(try Data(contentsOf: candidate.url) == before)
        }
    }

    @Test func `receipt rejects replaced source inode with identical bytes`() throws {
        try withCandidate { sourceURL, candidate, id, _ in
            let event = JournalEvent(
                action: .observation(dayID: id, start: 110, end: 120), now: 120
            )
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                event, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let replacement = sourceURL.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: sourceURL, to: replacement)
            try FileManager.default.removeItem(at: sourceURL)
            try FileManager.default.moveItem(at: replacement, to: sourceURL)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 130
            ) == .indeterminate)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }
}
