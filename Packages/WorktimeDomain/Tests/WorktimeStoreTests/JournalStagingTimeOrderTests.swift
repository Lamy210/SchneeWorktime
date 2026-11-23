import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingTimeOrderTests {
    private func withCandidate(
        _ body: (URL, JournalStagingCandidate, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let repository = try CatalogRepository(url: sourceURL, createIfMissing: true)
        let initial = try repository.load(now: 90)
        let dayID = UUID()
        _ = try repository.apply(
            .clockIn(id: dayID, profile: WorkdayProfile()), at: 100, now: 100,
            expected: initial.version
        )
        let candidate = try JournalStagingDatabase.createFromPreservedSource(
            at: sourceURL, in: root, now: 110
        )
        try body(sourceURL, candidate, dayID)
    }

    private func setRowPayload(_ row: JournalEventRow, at url: URL) throws {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        try #require(opened == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let hex = row.payload.map { String(format: "%02X", $0) }.joined()
        let statement = "UPDATE journal_event SET payload = X'\\(hex)' WHERE sequence = \\(row.sequence)"
        try #require(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
    }

    @Test func `valid chronological candidate appends remain inspectable`() throws {
        try withCandidate { sourceURL, candidate, dayID in
            let observation = JournalEvent(
                action: .observation(dayID: dayID, start: 110, end: 120), now: 150
            )
            let first = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observation, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 160
            )
            let plan = JournalEvent(
                action: .futureRest(dayID: dayID, remainingSeconds: 60), now: 160
            )
            let second = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                plan, sourceURL: sourceURL, candidate: candidate, expected: first.version, now: 160
            )
            let inspected = try JournalStagingDatabase.inspect(candidate.url, now: 170)
            #expect(inspected.version == second.version)
            #expect(inspected.catalog == second.catalog)
        }
    }

    @Test func `retrograde candidate row fails inspection without mutation`() throws {
        try withCandidate { sourceURL, candidate, dayID in
            let observation = JournalEvent(
                action: .observation(dayID: dayID, start: 110, end: 120), now: 150
            )
            let first = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                observation, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 160
            )
            let plan = JournalEvent(
                action: .futureRest(dayID: dayID, remainingSeconds: 60), now: 160
            )
            let receipt = try JournalStagingDatabase.captureOfflineAppendAttempt(
                plan, sourceURL: sourceURL, candidate: candidate, expected: first.version, now: 160
            )
            let second = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                plan, sourceURL: sourceURL, candidate: candidate, expected: first.version, now: 160
            )
            let retrograde = JournalEvent(
                action: .futureRest(dayID: dayID, remainingSeconds: 60), now: 130
            )
            let alteredRow = try JournalRowCodec.encode(retrograde, sequence: second.version.revision)
            var replayRows = second.rows
            replayRows[replayRows.count - 1] = alteredRow
            let replay = try JournalRowCodec.replay(
                replayRows, revision: second.version.revision, now: 170
            )
            #expect(replay.activeID == dayID)

            let sourceBytes = try Data(contentsOf: sourceURL)
            try setRowPayload(alteredRow, at: candidate.url)
            let candidateBytes = try Data(contentsOf: candidate.url)
            #expect(throws: JournalMigrationError.invalidEvent) {
                try JournalStagingDatabase.inspect(candidate.url, now: 170)
            }
            #expect(JournalStagingDatabase.inspectUncertainOfflineAppend(
                receipt, sourceURL: sourceURL, candidate: candidate, now: 170
            ) == .indeterminate)
            #expect(try Data(contentsOf: sourceURL) == sourceBytes)
            #expect(try Data(contentsOf: candidate.url) == candidateBytes)
        }
    }
}
