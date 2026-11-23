import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingAppendOutcomeTests {
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

    @Test func `identical journal events produce identical encoded row bytes`() throws {
        let id = UUID()
        let event = observation(id)
        let first = try JournalRowCodec.encode(event, sequence: 2)
        for _ in 0 ..< 32 {
            let again = try JournalRowCodec.encode(event, sequence: 2)
            #expect(again == first)
        }
    }

    @Test func `no event appears when append was never attempted`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let expected = candidate.draft.candidateVersion
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: expected, now: 130
            )
            #expect(result == .appendNotObserved(expected))
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `exactly matching committed event is observed without extra writes`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let expected = candidate.draft.candidateVersion
            let event = observation(id)
            let committed = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                event, sourceURL: sourceURL, candidate: candidate, expected: expected, now: 130
            )
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let outcome = JournalStagingDatabase.inspectUncertainOfflineAppend(
                event, sourceURL: sourceURL, candidate: candidate, expected: expected, now: 130
            )
            #expect(outcome == .matchingAppendObserved(committed.version))
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        }
    }

    @Test func `different event at the target revision is indeterminate`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let expected = candidate.draft.candidateVersion
            let other = JournalEvent(action: .futureRest(dayID: id, remainingSeconds: 60), now: 120)
            _ = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                other, sourceURL: sourceURL, candidate: candidate, expected: expected, now: 130
            )
            let saved = try Data(contentsOf: candidate.url)
            let outcome = JournalStagingDatabase.inspectUncertainOfflineAppend(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: expected, now: 130
            )
            #expect(outcome == .indeterminate)
            #expect(try Data(contentsOf: candidate.url) == saved)
        }
    }

    @Test func `source checkpoint changed after staging makes outcome indeterminate`() throws {
        try fixture { sourceURL, candidate, id, sourceVersion in
            let store = try SnapshotStore(url: sourceURL)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: sourceVersion)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `unbound candidate and wrong epoch must fail closed`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let event = observation(id)
            let wrong = StoreVersion(epoch: UUID(), revision: candidate.draft.candidateVersion.revision)
            #expect(JournalStagingDatabase.inspectUncertainOfflineAppend(
                event, sourceURL: sourceURL, candidate: candidate, expected: wrong, now: 130
            ) == .indeterminate)
            let plain = try JournalStagingDatabase.create(
                source: candidate.draft.source, in: sourceURL.deletingLastPathComponent(), now: 110
            )
            #expect(JournalStagingDatabase.inspectUncertainOfflineAppend(
                event, sourceURL: sourceURL, candidate: plain,
                expected: plain.draft.candidateVersion, now: 130
            ) == .indeterminate)
        }
    }

    @Test func `future event is indeterminate`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let expected = candidate.draft.candidateVersion
            let futureEvent = JournalEvent(
                action: .observation(dayID: id, start: 110, end: 120), now: 140
            )
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                futureEvent, sourceURL: sourceURL, candidate: candidate,
                expected: expected, now: 130
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `candidate inode swap is indeterminate`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let candidateBytes = try Data(contentsOf: candidate.url)
            try replaceWithIdenticalCopy(candidate.url)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `source inode swap is indeterminate`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            try replaceWithIdenticalCopy(sourceURL)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `later append is indeterminate`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let expected = candidate.draft.candidateVersion
            let first = observation(id)
            let committed = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                first, sourceURL: sourceURL, candidate: candidate,
                expected: expected, now: 130
            )
            let later = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            _ = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                later, sourceURL: sourceURL, candidate: candidate,
                expected: committed.version, now: 140
            )
            let candidateBytes = try Data(contentsOf: candidate.url)
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                first, sourceURL: sourceURL, candidate: candidate,
                expected: expected, now: 140
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `second append cannot match without a pinned pre-append prefix`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let first = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let second = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            _ = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                second, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 140
            )
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                second, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 140
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }

    @Test func `second append cannot report absent without a pinned pre-append prefix`() throws {
        try fixture { sourceURL, candidate, id, _ in
            let first = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observation(id), sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let second = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            let sourceBytes = try Data(contentsOf: sourceURL)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                second, sourceURL: sourceURL, candidate: candidate,
                expected: first.version, now: 140
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }}
