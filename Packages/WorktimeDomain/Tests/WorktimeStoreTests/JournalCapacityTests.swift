import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalCapacityTests {
    @Test func `event capacity reserves admission headroom and warns before the threshold`() {
        #expect(JournalCapacity(revision: 9499).shouldWarn == false)
        #expect(JournalCapacity(revision: 9500).shouldWarn)
        #expect(JournalCapacity(revision: 9899).canOpenWorkday)
        #expect(JournalCapacity(revision: 9900).canOpenWorkday == false)
        #expect(JournalCapacity(revision: 10000).remainingEvents == 0)
    }

    private func fixture(id: UUID) -> CatalogJournal {
        var journal = CatalogJournal()
        let start = JournalCommand.clockIn(id: id, target: 25200, expectedRest: 3600)
        journal.events.append(.init(action: .command(start, at: 100), now: 100))
        for index in 1 ..< 9899 {
            let now = Int64(100 + index)
            journal.events.append(.init(action: .futureRest(dayID: id, remainingSeconds: Int64(index % 2)), now: now))
        }
        journal.events.append(.init(action: .command(.clockOut(confirmBreak: false), at: 10000), now: 10000))
        return journal
    }

    @Test func `nearly full ended catalog rejects new starts and resumes without history changes`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let store = try SnapshotStore(url: url, createIfMissing: true)
        let id = UUID()
        var journal = fixture(id: id)
        let resume = JournalEvent(action: .command(.resume(id: id), at: 10001), now: 10001)
        journal.events.append(resume)
        let payload = try JSONEncoder().encode(journal)
        let source = StoredSnapshot(
            version: .init(epoch: UUID(), revision: Int64(journal.events.count)),
            payload: payload
        )
        let activeVersion = try store.seedRecovery(source, expected: store.load().version)
        let repository = try CatalogRepository(url: url)
        #expect(activeVersion.revision == 9901)
        // A legacy active day near the limit must still be able to close.
        let ended = try repository.apply(.clockOut(confirmBreak: false),
                                         at: 10002, now: 10002, expected: activeVersion)
        let version = ended.version
        #expect(ended.catalog.activeID == nil)
        let before = try store.load()
        #expect(version.revision == 9902)
        #expect(throws: CatalogPersistenceError.insufficientStartCapacity) {
            try repository.apply(.resume(id: id), at: 10003, now: 10003, expected: version)
        }
        #expect(throws: CatalogPersistenceError.insufficientStartCapacity) {
            try repository.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 10003, now: 10003, expected: version
            )
        }
        #expect(try store.load() == before)
    }

    private func withActiveCatalog(
        eventCount: Int, _ body: (CatalogRepository, SnapshotStore, StoreVersion, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let store = try SnapshotStore(url: url, createIfMissing: true)
        let id = UUID()
        let start = JournalCommand.clockIn(id: id, target: 25200, expectedRest: 3600)
        var journal = CatalogJournal(events: [.init(action: .command(start, at: 100), now: 100)])
        for index in 1 ..< eventCount {
            let now = Int64(100 + index)
            journal.events.append(.init(action: .futureRest(dayID: id, remainingSeconds: Int64(index % 2)), now: now))
        }
        let source = StoredSnapshot(
            version: .init(epoch: UUID(), revision: Int64(eventCount)),
            payload: try JSONEncoder().encode(journal)
        )
        let version = try store.seedRecovery(source, expected: store.load().version)
        try body(CatalogRepository(url: url), store, version, id)
    }

    @Test func `last available event can close an active workday without dropping history`() throws {
        try withActiveCatalog(eventCount: CatalogJournal.maxEvents - 1) { repo, store, version, id in
            let before = try repo.load(now: 10200)
            #expect(before.catalog.activeID == id)
            #expect(before.journalCapacity.remainingEvents == 1)
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 10200, now: 10200, expected: version)
            #expect(ended.catalog.activeID == nil)
            #expect(ended.version.revision == Int64(CatalogJournal.maxEvents))
            #expect(ended.journalCapacity.remainingEvents == 0)
            #expect(try ended.catalog.snapshot(dayID: id, now: 10200).bounds.lower == 10100)
            let persisted = try store.load()
            #expect(persisted == ended.validatedSnapshot)
            #expect(try repo.load(now: 10201).catalog == ended.catalog)
        }
    }

    @Test func `full active journal refuses additional writes but remains readable and exportable`() throws {
        try withActiveCatalog(eventCount: CatalogJournal.maxEvents) { repo, store, version, id in
            let before = try repo.load(now: 10200)
            #expect(before.catalog.activeID == id)
            #expect(before.journalCapacity.remainingEvents == 0)
            let original = try store.load()
            #expect(throws: CatalogPersistenceError.eventLimit) {
                try repo.apply(.clockOut(confirmBreak: false), at: 10200, now: 10200, expected: version)
            }
            #expect(try store.load() == original)
            let restored = try repo.load(now: 10201)
            #expect(restored.catalog == before.catalog)
            #expect(restored.version == version)
            let archive = try repo.makeBackup(now: 10201, expected: version)
            #expect(try CatalogBackup.inspect(archive, now: 10201).catalog == before.catalog)
        }
    }
}
