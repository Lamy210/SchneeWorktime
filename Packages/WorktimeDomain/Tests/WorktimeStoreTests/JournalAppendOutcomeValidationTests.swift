import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalAppendOutcomeValidationTests {
    private func withCandidate(
        _ body: (URL, JournalStagingCandidate, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
        let original = try repo.load(now: 90)
        let id = UUID()
        _ = try repo.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
            expected: original.version
        )
        let candidate = try JournalStagingDatabase.createFromPreservedSource(
            at: sourceURL, in: root, now: 110
        )
        try body(sourceURL, candidate, id)
    }

    @Test func `unreceipted result rejects retrograde attempt without writes`() throws {
        try withCandidate { sourceURL, candidate, id in
            let sourceBefore = try Data(contentsOf: sourceURL)
            let candidateBefore = try Data(contentsOf: candidate.url)
            let impossible = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 99
            )
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                impossible, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: sourceURL) == sourceBefore)
            #expect(try Data(contentsOf: candidate.url) == candidateBefore)
        }
    }

    @Test func `unreceipted result rejects invalid domain action without writes`() throws {
        try withCandidate { sourceURL, candidate, _ in
            let sourceBefore = try Data(contentsOf: sourceURL)
            let candidateBefore = try Data(contentsOf: candidate.url)
            let impossible = JournalEvent(
                action: .futureRest(dayID: UUID(), remainingSeconds: 60), now: 130
            )
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                impossible, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            #expect(result == .indeterminate)
            #expect(try Data(contentsOf: sourceURL) == sourceBefore)
            #expect(try Data(contentsOf: candidate.url) == candidateBefore)
        }
    }

    @Test func `valid unreceipted attempt still reports not observed without writes`() throws {
        try withCandidate { sourceURL, candidate, id in
            let original = try Data(contentsOf: candidate.url)
            let event = JournalEvent(
                action: .observation(dayID: id, start: 110, end: 120), now: 120
            )
            let expected = candidate.draft.candidateVersion
            let result = JournalStagingDatabase.inspectUncertainOfflineAppend(
                event, sourceURL: sourceURL, candidate: candidate,
                expected: expected, now: 130
            )
            #expect(result == .appendNotObserved(expected))
            #expect(try Data(contentsOf: candidate.url) == original)
        }
    }
}
