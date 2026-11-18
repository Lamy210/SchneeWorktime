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
}
