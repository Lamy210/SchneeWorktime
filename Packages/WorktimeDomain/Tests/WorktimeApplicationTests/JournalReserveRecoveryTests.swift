import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalReserveRecoveryTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withLegacyActiveDay(
        remaining: Int, _ body: (URL, CatalogRepository, CatalogSession, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let store = try SnapshotStore(url: url, createIfMissing: true)
        let id = UUID()
        let start = JournalCommand.clockIn(id: id, target: 25200, expectedRest: 3600)
        var journal = CatalogJournal(events: [.init(action: .command(start, at: 100), now: 100)])
        let count = CatalogJournal.maxEvents - remaining
        for index in 1 ..< count {
            let now = Int64(100 + index)
            journal.events.append(.init(action: .futureRest(dayID: id, remainingSeconds: Int64(index % 2)), now: now))
        }
        let payload = try JSONEncoder().encode(journal)
        let source = StoredSnapshot(version: .init(epoch: UUID(), revision: Int64(count)), payload: payload)
        let version = try store.seedRecovery(source, expected: store.load().version)
        let repo = try CatalogRepository(url: url)
        try repo.saveObservationCheckpoint(dayID: id, observedAt: 10200, expected: version)
        try body(url, repo, repo.load(now: 10200), id)
    }

    @Test func `restart with two slots records uncertainty before confirmed exit`() throws {
        try withLegacyActiveDay(remaining: 2) { url, repo, before, id in
            var controller = try WorktimeController(url: url, sample: sample(10220))
            #expect(controller.journalCapacity.remainingEvents == 1)
            let observed = try repo.load(now: 10220)
            let gap = ObservationGap(start: 10200, end: 10220)
            #expect(observed.catalog.observations[id] == [gap])
            #expect(observed.version.revision == before.version.revision + 1)
            let result = try controller.perform(.clockOut(confirmBreak: false), sample: sample(10221))
            let ended = try #require(result)
            #expect(ended.day.state == .ended)
            #expect(ended.snapshot.bounds.lower == 10101)
            #expect(ended.snapshot.bounds.upper == 10121)
            let saved = try repo.load(now: 10221)
            #expect(saved.catalog.activeID == nil)
            #expect(saved.catalog.observations[id] == [gap])
            #expect(saved.version.revision == before.version.revision + 2)
            #expect(saved.journalCapacity.remainingEvents == 0)
            var reopened = try WorktimeController(url: url, sample: sample(10300))
            let restored = try reopened.refresh(sample: sample(10301))
            #expect(restored?.snapshot.bounds == ended.snapshot.bounds)
            #expect(try repo.load(now: 10301).catalog == saved.catalog)
        }
    }

    @Test func `clock out cannot bypass a new observation when only one slot remains`() throws {
        try withLegacyActiveDay(remaining: 1) { url, repo, before, id in
            var controller = try WorktimeController(url: url, sample: sample(10200))
            let marker = try repo.loadObservationCheckpoint(expected: before.version)
            #expect(marker?.dayID == id)
            #expect(throws: CatalogPersistenceError.reservedExitCapacity) {
                try controller.perform(.clockOut(confirmBreak: false), sample: sample(10220))
            }
            let saved = try repo.load(now: 10220)
            #expect(saved.validatedSnapshot == before.validatedSnapshot)
            #expect(saved.catalog == before.catalog)
            #expect(saved.catalog.activeID == id)
            #expect(try repo.loadObservationCheckpoint(expected: before.version) == marker)
            #expect(throws: CatalogPersistenceError.reservedExitCapacity) {
                try WorktimeController(url: url, sample: sample(10221))
            }
            #expect(try repo.load(now: 10221).validatedSnapshot == before.validatedSnapshot)
        }
    }

    @Test func `full active journal refuses recovery without changing backup source`() throws {
        try withLegacyActiveDay(remaining: 0) { url, repo, before, id in
            let marker = try repo.loadObservationCheckpoint(expected: before.version)
            #expect(marker?.dayID == id)
            #expect(throws: CatalogPersistenceError.eventLimit) {
                try WorktimeController(url: url, sample: sample(10220))
            }
            let saved = try repo.load(now: 10220)
            #expect(saved.validatedSnapshot == before.validatedSnapshot)
            #expect(saved.catalog == before.catalog)
            #expect(try repo.loadObservationCheckpoint(expected: before.version) == marker)
            let archive = try repo.makeBackup(now: 10220, expected: before.version)
            let inspected = try CatalogBackup.inspect(archive, now: 10220)
            #expect(inspected.catalog == before.catalog)
            #expect(inspected.validatedSnapshot == before.validatedSnapshot)
        }
    }

    @Test(arguments: [0, 1])
    func `exhausted startup preserves full journal through read only backup`(remaining: Int) throws {
        try withLegacyActiveDay(remaining: remaining) { url, repo, before, id in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: output) }
            let destination = output.appendingPathComponent("preserved.json")
            let sourceBytes = try Data(contentsOf: url)
            let originalCheckpoint = try repo.loadObservationCheckpoint(expected: before.version)
            #expect(originalCheckpoint?.dayID == id)

            // Normal controller startup is blocked when an observation must be
            // recorded but schema-1 has no remaining safe event capacity.
            if remaining == 0 {
                #expect(throws: CatalogPersistenceError.eventLimit) {
                    try WorktimeController(url: url, sample: sample(10220))
                }
            } else {
                #expect(throws: CatalogPersistenceError.reservedExitCapacity) {
                    try WorktimeController(url: url, sample: sample(10220))
                }
            }

            // Rescue must not depend on a successfully initialized controller,
            // append an observation, or rewrite the original checkpoint.
            try PreservationBackup.write(from: url, to: destination, now: 10220)
            let saved = try CatalogBackup.inspectFile(at: destination, now: 10220)
            #expect(saved.validatedSnapshot == before.validatedSnapshot)
            #expect(saved.catalog == before.catalog)
            #expect(try Data(contentsOf: url) == sourceBytes)
            #expect(try repo.loadObservationCheckpoint(expected: before.version) == originalCheckpoint)
            #expect(throws: BackupFileError.self) {
                try PreservationBackup.write(from: url, to: destination, now: 10220)
            }
            #expect(try Data(contentsOf: url) == sourceBytes)
        }
    }
}
