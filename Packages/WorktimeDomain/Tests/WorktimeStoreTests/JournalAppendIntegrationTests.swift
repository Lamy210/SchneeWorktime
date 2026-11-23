import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalAppendIntegrationTests {
    private func fixture(
        _ body: (URL, JournalStagingCandidate, UUID) throws -> Void
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
        _ = try repo.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
            expected: initial.version
        )
        let candidate = try JournalStagingDatabase.createFromPreservedSource(
            at: sourceURL, in: root, now: 110
        )
        try body(sourceURL, candidate, id)
    }

    @Test func `direct append rejects retrograde event without mutating candidate`() throws {
        try fixture { sourceURL, candidate, id in
            let before = try Data(contentsOf: candidate.url)
            let sourceBefore = try Data(contentsOf: sourceURL)
            let invalid = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 99
            )
            #expect(throws: JournalMigrationError.invalidEvent) {
                try JournalStagingDatabase.appendOffline(
                    invalid, to: candidate.url, anchoredTo: candidate.draft.source,
                    expected: candidate.draft.candidateVersion, now: 130
                )
            }
            #expect(try Data(contentsOf: candidate.url) == before)
            #expect(try Data(contentsOf: sourceURL) == sourceBefore)
        }
    }

    @Test func `source fenced append and receipt reject retrograde event identically`() throws {
        try fixture { sourceURL, candidate, id in
            let before = try Data(contentsOf: candidate.url)
            let sourceBefore = try Data(contentsOf: sourceURL)
            let invalid = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 99
            )
            let expected = candidate.draft.candidateVersion
            #expect(throws: JournalMigrationError.invalidEvent) {
                try JournalStagingDatabase.captureOfflineAppendAttempt(
                    invalid, sourceURL: sourceURL, candidate: candidate,
                    expected: expected, now: 130
                )
            }
            #expect(throws: JournalMigrationError.invalidEvent) {
                try JournalStagingDatabase.appendOfflineFromPreservedSource(
                    invalid, sourceURL: sourceURL, candidate: candidate,
                    expected: expected, now: 130
                )
            }
            #expect(try Data(contentsOf: candidate.url) == before)
            #expect(try Data(contentsOf: sourceURL) == sourceBefore)
        }
    }

    @Test func `shared validated append still allows two commits and reinspection`() throws {
        try fixture { sourceURL, candidate, id in
            let first = JournalEvent(
                action: .observation(dayID: id, start: 110, end: 120), now: 120
            )
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                first, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            let saved = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                first, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 130
            )
            #expect(JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 130
            ) == .matchingAppendObserved(saved.version))
            let next = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            let second = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                next, sourceURL: sourceURL, candidate: candidate,
                expected: saved.version, now: 140
            )
            #expect(second.version.revision == saved.version.revision + 1)
            #expect(second.rows.count == Int(second.version.revision))
            #expect(second.catalog.activeID == id)
            #expect(try JournalStagingDatabase.inspect(candidate.url, now: 140).catalog == second.catalog)
        }
    }
}
