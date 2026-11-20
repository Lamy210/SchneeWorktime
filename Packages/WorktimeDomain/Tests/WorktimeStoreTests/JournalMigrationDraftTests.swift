import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalMigrationDraftTests {
    private func fullJournal(id: UUID) -> CatalogJournal {
        let start = JournalCommand.clockIn(id: id, target: 25200, expectedRest: 3600)
        var journal = CatalogJournal(events: [.init(action: .command(start, at: 100), now: 100)])
        journal.events.append(.init(action: .observation(dayID: id, start: 110, end: 120), now: 120))
        journal.events.append(.init(action: .review(dayID: id, start: 110, end: 120, classification: .rest), now: 121))
        for index in 3 ..< CatalogJournal.maxEvents {
            let now = Int64(200 + index)
            journal.events.append(.init(action: .futureRest(dayID: id, remainingSeconds: Int64(index % 2)), now: now))
        }
        return journal
    }

    @Test func `full legacy migration retains audit and permits replay beyond legacy limit`() throws {
        let id = UUID()
        let journal = fullJournal(id: id)
        let payload = try JSONEncoder().encode(journal)
        let source = StoredSnapshot(version: .init(epoch: UUID(), revision: 10000), payload: payload)
        let before = try CatalogBackup.validateSnapshot(source, now: 10300)
        let draft = try JournalMigrationDraft(source: source, now: 10300)
        #expect(draft.source == source)
        #expect(draft.candidateVersion.epoch != source.version.epoch)
        #expect(draft.candidateVersion.revision == source.version.revision)
        #expect(try JournalRowCodec.decode(draft.rows, revision: 10000) == journal.events)
        #expect(try JournalRowCodec.replay(draft.rows, revision: 10000, now: 10300) == before.catalog)
        var rows = draft.rows
        let gap = JournalEvent(action: .observation(dayID: id, start: 10300, end: 10320), now: 10320)
        let gapRow = try JournalRowCodec.encode(gap, sequence: 10001)
        rows.append(gapRow)
        let exit = JournalEvent(action: .command(.clockOut(confirmBreak: false), at: 10321), now: 10321)
        let exitRow = try JournalRowCodec.encode(exit, sequence: 10002)
        rows.append(exitRow)
        let ended = try JournalRowCodec.replay(rows, revision: 10002, now: 10321)
        #expect(ended.activeID == nil)
        #expect(ended.reviewAudit == before.catalog.reviewAudit)
        #expect(ended.observations[id] == [.init(start: 10300, end: 10320)])
        let actual = try ended.snapshot(dayID: id, now: 10321)
        #expect(actual.bounds.lower == 10191)
        #expect(actual.bounds.upper == 10211)
        #expect(draft.source.payload == payload)
        #expect(draft.rows.count == 10000)
    }

    @Test func `row validation rejects missing duplicate reordered and oversized events`() throws {
        let first = try JournalRowCodec.encode(
            .init(action: .command(.clockIn(id: UUID(), target: 25200, expectedRest: 3600), at: 100), now: 100),
            sequence: 1
        )
        let second = try JournalRowCodec.encode(
            .init(action: .command(.clockOut(confirmBreak: false), at: 200), now: 200), sequence: 2
        )
        #expect(throws: JournalMigrationError.invalidSequence) {
            try JournalRowCodec.decode([first], revision: 2)
        }
        #expect(throws: JournalMigrationError.invalidSequence) {
            try JournalRowCodec.decode([first, first], revision: 2)
        }
        #expect(throws: JournalMigrationError.invalidSequence) {
            try JournalRowCodec.decode([second, first], revision: 2)
        }
        let invalid = JournalEventRow(sequence: 1, payload: Data([1]))
        #expect(throws: JournalMigrationError.invalidEvent) {
            try JournalRowCodec.decode([invalid], revision: 1)
        }
        let large = JournalEventRow(sequence: 1, payload: Data(count: JournalRowCodec.maxRowBytes + 1))
        #expect(throws: JournalMigrationError.byteLimit) {
            try JournalRowCodec.decode([large], revision: 1)
        }
        #expect(throws: CatalogPersistenceError.futureEvent) {
            try JournalRowCodec.replay([first, second], revision: 2, now: 199)
        }
    }

    @Test func `empty or invalid legacy input is validated before candidate creation`() throws {
        let empty = StoredSnapshot(version: .init(epoch: UUID(), revision: 0), payload: nil)
        let draft = try JournalMigrationDraft(source: empty, now: 100)
        #expect(draft.rows.isEmpty)
        #expect(draft.candidateVersion.epoch != empty.version.epoch)
        #expect(try JournalRowCodec.replay(draft.rows, revision: 0, now: 100) == WorkdayCatalog())
        let invalid = StoredSnapshot(version: .init(epoch: UUID(), revision: 1), payload: Data([1]))
        #expect(throws: CatalogPersistenceError.invalidJournal) {
            try JournalMigrationDraft(source: invalid, now: 100)
        }
    }
}
