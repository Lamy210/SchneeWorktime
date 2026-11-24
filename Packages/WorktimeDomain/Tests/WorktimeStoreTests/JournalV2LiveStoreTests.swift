import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2LiveStoreTests {
    private func fixture(_ body: (URL, JournalV2LiveStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let store = try JournalV2LiveStore(url: url, createIfMissing: true)
        try body(url, store)
    }

    private func clockIn(_ id: UUID, now: Int64 = 100) -> JournalEvent {
        JournalEvent(
            action: .command(
                .clockIn(id: id, target: 25200, expectedRest: 3600), at: now
            ),
            now: now
        )
    }

    private func tamper(_ url: URL, sql: String) throws {
        var pointer: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(pointer) }
        try #require(sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func `schema two capacity keeps space for safe exit`() {
        let maxRows = Int64(JournalRowCodec.maxRows)
        let canStart = JournalCapacity(revision: maxRows - 101, limit: maxRows)
        #expect(canStart.canOpenWorkday)
        let cannotStart = JournalCapacity(revision: maxRows - 100, limit: maxRows)
        #expect(!cannotStart.canOpenWorkday)
        let two = JournalCapacity(revision: maxRows - 2, limit: maxRows)
        #expect(two.isExitReserve)
        #expect(two.allowsActiveMutation(.observation(dayID: UUID(), start: 10, end: 11)))
        #expect(!two.allowsActiveMutation(.futureRest(dayID: UUID(), remainingSeconds: 60)))
        let one = JournalCapacity(revision: maxRows - 1, limit: maxRows)
        #expect(!one.allowsActiveMutation(.observation(dayID: UUID(), start: 10, end: 11)))
        #expect(one.allowsActiveMutation(.command(.clockOut(confirmBreak: false), at: 12)))
        let exhausted = JournalCapacity(revision: maxRows, limit: maxRows)
        #expect(!exhausted.allowsActiveMutation(.command(.clockOut(confirmBreak: false), at: 12)))
    }

    @Test func `fresh schema two stores journal and replays on reopening`() throws {
        try fixture { url, store in
            let initial = try store.load(now: 99)
            #expect(initial.version.revision == 0)
            #expect(initial.rows.isEmpty)
            let id = UUID()
            let started = try store.append(clockIn(id), matching: initial, now: 100)
            let observed = try store.append(
                .init(action: .observation(dayID: id, start: 110, end: 120), now: 120),
                matching: started, now: 120
            )
            #expect(observed.version.epoch == started.version.epoch)
            #expect(observed.version.revision == 2)
            #expect(observed.catalog.activeID == id)
            let reopened = try JournalV2LiveStore(url: url)
            let disk = try reopened.load(now: 130)
            #expect(disk.version == observed.version)
            #expect(disk.rows == observed.rows)
            #expect(disk.catalog == observed.catalog)
            #expect(try !Data(contentsOf: url).isEmpty)
        }
    }

    @Test func `stale version cannot overwrite a committed journal event`() throws {
        try fixture { url, store in
            let expected = try store.load(now: 100)
            let id = UUID()
            let committed = try store.append(clockIn(id), matching: expected, now: 100)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try store.append(clockIn(UUID()), matching: expected, now: 101)
            }
            let disk = try JournalV2LiveStore(url: url).load(now: 110)
            #expect(disk.rows == committed.rows)
            #expect(disk.version == committed.version)
        }
    }

    @Test func `same revision byte mutation fails exact prestate fence`() throws {
        try fixture { url, store in
            let id = UUID()
            let started = try store.append(clockIn(id), matching: store.load(now: 100), now: 100)
            try tamper(
                url, sql: "UPDATE journal_event SET payload = CAST(' ' || CAST(payload AS TEXT) AS BLOB)"
            )
            let before = try Data(contentsOf: url)
            let event = JournalEvent(action: .futureRest(dayID: id, remainingSeconds: 60), now: 110)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try store.append(event, matching: started, now: 110)
            }
            #expect(try Data(contentsOf: url) == before)
            #expect(try store.load(now: 110).version == started.version)
        }
    }

    @Test func `fresh store refuses schema one without resetting it`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let legacy = try CatalogRepository(url: url, createIfMissing: true)
        let id = UUID()
        let initial = try legacy.load(now: 90)
        let started = try legacy.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
            expected: initial.version
        )
        let bytes = try Data(contentsOf: url)
        #expect(throws: SnapshotStoreError.unsupportedSchema) {
            try JournalV2LiveStore(url: url, createIfMissing: true)
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try legacy.load(now: 110).version == started.version)
    }

    @Test func `reset fences old epoch and never revives deleted events`() throws {
        try fixture { url, store in
            let started = try store.append(
                clockIn(UUID()), matching: store.load(now: 100), now: 100
            )
            let cleared = try store.reset(matching: started, now: 110)
            #expect(cleared.version.epoch != started.version.epoch)
            #expect(cleared.version.revision == 0)
            #expect(cleared.rows.isEmpty)
            #expect(cleared.catalog == WorkdayCatalog())
            #expect(throws: SnapshotStoreError.staleVersion) {
                try store.append(clockIn(UUID()), matching: started, now: 120)
            }
            let reopened = try JournalV2LiveStore(url: url).load(now: 120)
            #expect(reopened.version == cleared.version)
            #expect(reopened.rows.isEmpty)
        }
    }

    @Test func `invalid event or future time leaves new store unchanged`() throws {
        try fixture { url, store in
            let initial = try store.load(now: 100)
            let bytes = try Data(contentsOf: url)
            let bad = JournalEvent(action: .command(.endBreak, at: 100), now: 100)
            #expect(throws: WorkdayError.noActiveDay) {
                try store.append(bad, matching: initial, now: 100)
            }
            #expect(throws: CatalogPersistenceError.futureEvent) {
                try store.append(clockIn(UUID(), now: 200), matching: initial, now: 100)
            }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try store.load(now: 100).version == initial.version)
        }
    }

    @Test func `candidate schema two is not a valid live schema two database`() throws {
        try fixture { url, store in
            let root = url.deletingLastPathComponent()
            let source = StoredSnapshot(
                version: .init(epoch: UUID(), revision: 0), payload: nil
            )
            let candidate = try JournalStagingDatabase.create(source: source, in: root, now: 100)
            #expect(throws: SnapshotStoreError.self) {
                try JournalV2LiveStore(url: candidate.url)
            }
            #expect(try store.load(now: 100).version.revision == 0)
        }
    }

}

extension JournalV2LiveStoreTests {
    @Test func `atomic append persists checkpoint in the new journal generation`() throws {
        try fixture { url, store in
            let id = UUID()
            let initial = try store.load(now: 100)
            let started = try store.append(clockIn(id), matching: initial, now: 100, observedAt: 100)
            #expect(started.checkpoint?.version == started.version)
            #expect(started.checkpoint?.dayID == id)
            #expect(started.checkpoint?.observedAt == 100)
            let observation = JournalEvent(
                action: .observation(dayID: id, start: 110, end: 120), now: 120
            )
            let updated = try store.append(
                observation, matching: started, now: 120, observedAt: 120
            )
            #expect(updated.checkpoint?.version == updated.version)
            #expect(updated.checkpoint?.observedAt == 120)
            let reopened = try JournalV2LiveStore(url: url).load(now: 130)
            #expect(reopened.rows == updated.rows)
            #expect(reopened.checkpoint == updated.checkpoint)
        }
    }

    @Test func `append without a new clock observation clears the prior marker`() throws {
        try fixture { url, store in
            let id = UUID()
            let start = try store.append(
                clockIn(id), matching: store.load(now: 100), now: 100, observedAt: 100
            )
            let next = try store.append(
                .init(action: .futureRest(dayID: id, remainingSeconds: 60), now: 110),
                matching: start, now: 110
            )
            #expect(next.checkpoint == nil)
            #expect(try JournalV2LiveStore(url: url).load(now: 110).checkpoint == nil)
            #expect(next.version.revision == start.version.revision + 1)
        }
    }

    @Test func `invalid checkpoint rolls back the event and epoch revision`() throws {
        try fixture { url, store in
            let initial = try store.load(now: 100)
            #expect(throws: ObservationCheckpointError.invalid) {
                try store.append(clockIn(UUID()), matching: initial, now: 100, observedAt: 99)
            }
            let reloaded = try JournalV2LiveStore(url: url).load(now: 110)
            #expect(reloaded.version == initial.version)
            #expect(reloaded.rows == initial.rows)
            #expect(reloaded.checkpoint == nil)
            #expect(reloaded.catalog == initial.catalog)
        }
    }

    @Test func `checkpoint-only update is monotonic and does not change journal revision`() throws {
        try fixture { url, store in
            let id = UUID()
            let started = try store.append(clockIn(id), matching: store.load(now: 100), now: 100)
            let first = try store.saveObservationCheckpoint(
                dayID: id, observedAt: 110, matching: started, now: 110
            )
            #expect(first.version == started.version)
            let second = try store.saveObservationCheckpoint(
                dayID: id, observedAt: 120, matching: first, now: 120
            )
            #expect(second.rows == started.rows)
            #expect(second.checkpoint?.observedAt == 120)
            #expect(try JournalV2LiveStore(url: url).load(now: 130).checkpoint == second.checkpoint)
            #expect(throws: ObservationCheckpointError.regressed) {
                try store.saveObservationCheckpoint(
                    dayID: id, observedAt: 115, matching: second, now: 130
                )
            }
            #expect(throws: ObservationCheckpointError.invalid) {
                try store.saveObservationCheckpoint(
                    dayID: UUID(), observedAt: 121, matching: second, now: 130
                )
            }
        }
    }

    @Test func `checkpoint writers for stale revision are fenced`() throws {
        try fixture { url, store in
            let id = UUID()
            let started = try store.append(
                clockIn(id), matching: store.load(now: 100), now: 100, observedAt: 100
            )
            let updated = try store.append(
                .init(action: .futureRest(dayID: id, remainingSeconds: 60), now: 110),
                matching: started, now: 110
            )
            #expect(throws: SnapshotStoreError.staleVersion) {
                try store.saveObservationCheckpoint(
                    dayID: id, observedAt: 115, matching: started, now: 120
                )
            }
            #expect(updated.checkpoint == nil)
            #expect(try JournalV2LiveStore(url: url).load(now: 120).version == updated.version)
        }
    }

    @Test func `same revision checkpoint change fences stale journal append and reset`() throws {
        try fixture { url, store in
            let id = UUID()
            let started = try store.append(
                clockIn(id), matching: store.load(now: 100), now: 100, observedAt: 100
            )
            let updated = try store.saveObservationCheckpoint(
                dayID: id, observedAt: 105, matching: started, now: 105
            )
            #expect(updated.version == started.version)
            let event = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 110
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try store.append(event, matching: started, now: 110)
            }
            #expect(throws: JournalMigrationError.verificationFailed) {
                try store.reset(matching: started, now: 110)
            }
            let reopened = try JournalV2LiveStore(url: url).load(now: 110)
            #expect(reopened.checkpoint == updated.checkpoint)
            #expect(reopened.rows == updated.rows)
            #expect(reopened.version == updated.version)
        }
    }

    @Test func `tampered checkpoint cannot be loaded or silently reassigned`() throws {
        try fixture { url, store in
            let id = UUID()
            let started = try store.append(
                clockIn(id), matching: store.load(now: 100), now: 100, observedAt: 100
            )
            try tamper(url, sql: "UPDATE observation_checkpoint SET revision = 2")
            #expect(throws: ObservationCheckpointError.invalid) {
                try store.load(now: 130)
            }
            #expect(throws: ObservationCheckpointError.invalid) {
                try store.saveObservationCheckpoint(
                    dayID: id, observedAt: 110, matching: started, now: 130
                )
            }
        }
    }

    @Test func `logical reset removes old checkpoint in the same generation change`() throws {
        try fixture { url, store in
            let started = try store.append(
                clockIn(UUID()), matching: store.load(now: 100), now: 100, observedAt: 100
            )
            let cleared = try store.reset(matching: started, now: 110)
            #expect(cleared.checkpoint == nil)
            #expect(cleared.version.epoch != started.version.epoch)
            #expect(try JournalV2LiveStore(url: url).load(now: 120).checkpoint == nil)
        }
    }
}
