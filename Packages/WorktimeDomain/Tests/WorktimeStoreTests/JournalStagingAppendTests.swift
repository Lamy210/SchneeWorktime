import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

private actor StagingAppendGate {
    private var waiting: CheckedContinuation<Void, Never>?

    func meet() async {
        if let first = waiting {
            waiting = nil
            first.resume()
        } else {
            await withCheckedContinuation { waiting = $0 }
        }
    }
}

struct JournalStagingAppendTests {
    private func fixture(
        _ body: (JournalStagingCandidate, StoredSnapshot, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let event = JournalEvent(
            action: .command(.clockIn(id: id, target: 25200, expectedRest: 3600), at: 100), now: 100
        )
        let payload = try JSONEncoder().encode(CatalogJournal(events: [event]))
        let source = StoredSnapshot(version: .init(epoch: UUID(), revision: 1), payload: payload)
        let candidate = try JournalStagingDatabase.create(source: source, in: root, now: 200)
        try body(candidate, source, id)
    }

    @Test func `offline append preserves source and replays observation and exit`() throws {
        try fixture { candidate, source, id in
            let gap = JournalEvent(action: .observation(dayID: id, start: 110, end: 120), now: 120)
            let first = try JournalStagingDatabase.appendOffline(
                gap, to: candidate.url, anchoredTo: source, expected: candidate.draft.candidateVersion, now: 200
            )
            #expect(first.version.revision == 2)
            #expect(first.source == source)
            #expect(first.catalog.activeID == id)
            let exit = JournalEvent(action: .command(.clockOut(confirmBreak: false), at: 130), now: 130)
            let second = try JournalStagingDatabase.appendOffline(
                exit, to: candidate.url, anchoredTo: source, expected: first.version, now: 200
            )
            #expect(second.version.revision == 3)
            #expect(second.version.epoch == candidate.draft.candidateVersion.epoch)
            #expect(second.catalog.activeID == nil)
            #expect(second.catalog.observations[id] == [.init(start: 110, end: 120)])
            let reopened = try JournalStagingDatabase.inspect(candidate.url, now: 200)
            #expect(reopened.version == second.version)
            #expect(reopened.rows == second.rows)
            #expect(reopened.catalog == second.catalog)
            #expect(reopened.source == source)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try JournalStagingDatabase.appendOffline(
                    exit, to: candidate.url, anchoredTo: source,
                    expected: candidate.draft.candidateVersion, now: 200
                )
            }
        }
    }

    @Test func `invalid offline event leaves candidate untouched`() throws {
        try fixture { candidate, source, id in
            let before = try Data(contentsOf: candidate.url)
            let invalid = JournalEvent(action: .command(.endBreak, at: 110), now: 110)
            #expect(throws: WorkdayError.invalidTransition) {
                try JournalStagingDatabase.appendOffline(
                    invalid, to: candidate.url, anchoredTo: source,
                    expected: candidate.draft.candidateVersion, now: 200
                )
            }
            let saved = try JournalStagingDatabase.inspect(candidate.url, now: 200)
            #expect(saved.version == candidate.draft.candidateVersion)
            #expect(saved.catalog.activeID == id)
            let after = try Data(contentsOf: candidate.url)
            #expect(after == before)
        }
    }

    @Test func `competing offline writers commit only once`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let event = JournalEvent(
            action: .command(.clockIn(id: id, target: 25200, expectedRest: 3600), at: 100), now: 100
        )
        let payload = try JSONEncoder().encode(CatalogJournal(events: [event]))
        let source = StoredSnapshot(version: .init(epoch: UUID(), revision: 1), payload: payload)
        let candidate = try JournalStagingDatabase.create(source: source, in: root, now: 200)
        let gate = StagingAppendGate()
        let url = candidate.url
        let version = candidate.draft.candidateVersion
        let outcomes = await withTaskGroup(of: String.self) { group in
            for seconds in [60, 120] {
                group.addTask {
                    await gate.meet()
                    do {
                        let event = JournalEvent(
                            action: .futureRest(dayID: id, remainingSeconds: Int64(seconds)), now: 200
                        )
                        _ = try JournalStagingDatabase.appendOffline(
                            event, to: url, anchoredTo: source, expected: version, now: 200
                        )
                        return "saved"
                    } catch SnapshotStoreError.staleVersion {
                        return "stale"
                    } catch {
                        return "unexpected: \(error)"
                    }
                }
            }
            var values: [String] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        #expect(outcomes.sorted() == ["saved", "stale"])
        let saved = try JournalStagingDatabase.inspect(candidate.url, now: 200)
        #expect(saved.version.revision == version.revision + 1)
        #expect(saved.source == source)
        #expect(saved.catalog.activeID == id)
    }

    @Test func `full legacy journal can persist two additional events without erasing its audit trail`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let start = JournalCommand.clockIn(id: id, target: 25200, expectedRest: 3600)
        var journal = CatalogJournal(events: [.init(action: .command(start, at: 100), now: 100)])
        for index in 1 ..< CatalogJournal.maxEvents {
            let now = Int64(100 + index)
            journal.events.append(.init(action: .futureRest(dayID: id, remainingSeconds: Int64(index % 2)), now: now))
        }
        let payload = try JSONEncoder().encode(journal)
        let source = StoredSnapshot(version: .init(epoch: UUID(), revision: 10000), payload: payload)
        let candidate = try JournalStagingDatabase.create(source: source, in: root, now: 11000)
        let gap = JournalEvent(action: .observation(dayID: id, start: 10100, end: 10110), now: 11000)
        let observed = try JournalStagingDatabase.appendOffline(
            gap, to: candidate.url, anchoredTo: source, expected: candidate.draft.candidateVersion, now: 11000
        )
        #expect(observed.version.revision == 10001)
        let exit = JournalEvent(action: .command(.clockOut(confirmBreak: false), at: 11001), now: 11001)
        let ended = try JournalStagingDatabase.appendOffline(
            exit, to: candidate.url, anchoredTo: source, expected: observed.version, now: 11001
        )
        #expect(ended.version.revision == 10002)
        #expect(ended.catalog.activeID == nil)
        #expect(ended.catalog.observations[id] == [.init(start: 10100, end: 10110)])
        let reopened = try JournalStagingDatabase.inspect(candidate.url, now: 11002)
        #expect(reopened.source == source)
        #expect(reopened.source.payload == payload)
        #expect(reopened.rows.count == 10002)
        #expect(reopened.catalog == ended.catalog)
        #expect(reopened.catalog.reviewAudit == ended.catalog.reviewAudit)
    }


}
