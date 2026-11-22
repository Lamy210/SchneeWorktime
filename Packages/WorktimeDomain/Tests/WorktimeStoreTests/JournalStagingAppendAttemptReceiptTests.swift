import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingAppendAttemptReceiptTests {
    private func fixture(
        _ body: (URL, JournalStagingCandidate, UUID, StoreVersion) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
        let first = try repo.load(now: 90)
        let id = UUID()
        let active = try repo.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: first.version
        )
        let candidate = try JournalStagingDatabase.createFromPreservedSource(
            at: sourceURL, in: root, now: 110
        )
        try body(sourceURL, candidate, id, active.version)
    }

    private func observation(_ id: UUID) -> JournalEvent {
        JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
    }

    private func replaceWithIdenticalCopy(_ url: URL) throws {
        let replacement = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
    }

    @Test func `first append receipt observes a matching event`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let expected = candidate.draft.candidateVersion
            let event = observation(id)
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                event, sourceURL: sourceURL, candidate: candidate, expected: expected, now: 130
            )
            let committed = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                event, sourceURL: sourceURL, candidate: candidate, expected: expected, now: 130
            )
            let bytes = try Data(contentsOf: candidate.url)
            let outcome = JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 140
            )
            #expect(outcome == .matchingAppendObserved(committed.version))
            #expect(try Data(contentsOf: candidate.url) == bytes)
        }
    }

    @Test func `second append receipt observes a matching event`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let first = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let second = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                second, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 130
            )
            let committed = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                second, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 140
            )
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let outcome = JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 140
            )
            #expect(outcome == .matchingAppendObserved(committed.version))
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `second append receipt observes no event when unchanged`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let first = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let second = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                second, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 140
            )
            let candidateBytes = try Data(contentsOf: candidate.url)
            let outcome = JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 140
            )
            #expect(outcome == .appendNotObserved(first.version))
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `receipt rejects a different committed event`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let first = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let attempt = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            let alternative = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 120), now: 130
            )
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                attempt, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 140
            )
            _ = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                alternative, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 140
            )
            let outcome = JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 140
            )
            #expect(outcome == .indeterminate)
        }
    }

    @Test func `receipt rejects a later extra append`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let first = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let second = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                second, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 130
            )
            let committed = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                second, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 140
            )
            let third = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 30), now: 140
            )
            _ = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                third, sourceURL: sourceURL, candidate: candidate,
                expected: committed.version, now: 150
            )
            #expect(JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 150
            ) == .indeterminate)
        }
    }

    @Test func `receipt rejects identical bytes with a replaced candidate inode`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let bytes = try Data(contentsOf: candidate.url)
            try replaceWithIdenticalCopy(candidate.url)
            #expect(try Data(contentsOf: candidate.url) == bytes)
            #expect(JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 130
            ) == .indeterminate)
        }
    }
}
