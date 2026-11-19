import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalExitReserveTests {
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
        let payload = try JSONEncoder().encode(journal)
        let source = StoredSnapshot(
            version: .init(epoch: UUID(), revision: Int64(eventCount)), payload: payload
        )
        let version = try store.seedRecovery(source, expected: store.load().version)
        try body(CatalogRepository(url: url), store, version, id)
    }

    @Test func `optional changes cannot consume the exit reserve`() throws {
        try withActiveCatalog(eventCount: CatalogJournal.maxEvents - 3) { repo, store, version, id in
            let before = try repo.load(now: 10200)
            #expect(!before.journalCapacity.isExitReserve)
            let updated = try repo.setFutureRest(dayID: id, remainingSeconds: 120, now: 10200, expected: version)
            #expect(updated.journalCapacity.remainingEvents == 2)
            #expect(updated.journalCapacity.isExitReserve)
            let original = try store.load()
            #expect(throws: CatalogPersistenceError.reservedExitCapacity) {
                try repo.setFutureRest(dayID: id, remainingSeconds: 180, now: 10201, expected: updated.version)
            }
            #expect(throws: CatalogPersistenceError.reservedExitCapacity) {
                try repo.apply(.startBreak, at: 10201, now: 10201, expected: updated.version)
            }
            #expect(try store.load() == original)
            #expect(try repo.load(now: 10201).catalog == updated.catalog)
        }
    }

    @Test func `observation and exit use reserved slots without losing uncertainty`() throws {
        try withActiveCatalog(eventCount: CatalogJournal.maxEvents - 2) { repo, store, version, id in
            let gap = ObservationGap(start: 10100, end: 10110)
            let observed = try repo.recordObservation(dayID: id, gap: gap, now: 10200, expected: version)
            #expect(observed.journalCapacity.remainingEvents == 1)
            let original = try store.load()
            let duplicate = try repo.recordObservation(dayID: id, gap: gap, now: 10201, expected: observed.version)
            #expect(duplicate.version == observed.version)
            #expect(try store.load() == original)
            let nextGap = ObservationGap(start: 10120, end: 10130)
            #expect(throws: CatalogPersistenceError.reservedExitCapacity) {
                try repo.recordObservation(dayID: id, gap: nextGap, now: 10201, expected: observed.version)
            }
            #expect(try store.load() == original)
            // This directly exercises Store: an Application with a new unobserved gap must not bypass it.
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 10202, now: 10202,
                                       expected: observed.version)
            #expect(ended.catalog.activeID == nil)
            #expect(ended.journalCapacity.remainingEvents == 0)
            #expect(ended.catalog.observations[id] == [gap])
            let snapshot = try ended.catalog.snapshot(dayID: id, now: 10202)
            #expect(snapshot.bounds.lower == 10092)
            #expect(snapshot.bounds.upper == 10102)
            #expect(try repo.load(now: 10203).catalog == ended.catalog)
        }
    }
}
