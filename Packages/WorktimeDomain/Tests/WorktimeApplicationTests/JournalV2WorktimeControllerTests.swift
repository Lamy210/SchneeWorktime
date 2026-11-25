import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2WorktimeControllerTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("worktime.sqlite"), root)
    }

    @Test func `new schema two controller persists initial observation with clock in`() throws {
        try fixture { url, _ in
            var controller = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            #expect(controller.journalCapacity.remainingEvents == 100_000)
            let empty = try controller.refresh(sample: sample(100))
            #expect(empty?.day == nil)
            let startResult = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let started = try #require(startResult)
            #expect(started.day.state == .working)
            #expect(controller.version.revision == 1)
            #expect(controller.journalCapacity.remainingEvents == 99999)
            let persisted = try JournalV2Repository(url: url).load(now: 100)
            #expect(persisted.version == controller.version)
            #expect(persisted.checkpoint?.observedAt == 100)
            #expect(controller.checkpoint == persisted.checkpoint)
        }
    }

    @Test func `sleep gap is uncertain before clock out and survives reopening`() throws {
        try fixture { url, _ in
            var controller = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            _ = try controller.refresh(sample: sample(110))
            #expect(controller.checkpoint?.observedAt == 110)
            let gapResult = try controller.refresh(sample: sample(140))
            let gap = try #require(gapResult)
            #expect(gap.snapshot.bounds.lower == 10)
            #expect(gap.snapshot.bounds.upper == 40)
            #expect(controller.checkpoint?.observedAt == 140)
            let endedResult = try controller.perform(
                .clockOut(confirmBreak: false), sample: sample(150)
            )
            let ended = try #require(endedResult)
            // The ten seconds after the latest observation are verified work.
            #expect(ended.snapshot.bounds.lower == 20)
            #expect(ended.snapshot.bounds.upper == 50)
            #expect(controller.checkpoint == nil)
            let saved = try JournalV2Repository(url: url).load(now: 160)
            #expect(saved.catalog.observations[ended.day.id]?.count == 1)
            var reopened = try JournalV2WorktimeController(url: url, sample: sample(160))
            let restoredResult = try reopened.refresh(sample: sample(160))
            let result = try #require(restoredResult)
            #expect(result.snapshot == ended.snapshot)
        }
    }

    @Test func `relaunch records only the unobserved interval from durable checkpoint`() throws {
        try fixture { url, _ in
            var first = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            _ = try first.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            _ = try first.refresh(sample: sample(110))
            var reopened = try JournalV2WorktimeController(url: url, sample: sample(200))
            let currentResult = try reopened.refresh(sample: sample(210))
            let current = try #require(currentResult)
            // Checkpoint at 110 and live observation from 200 to 210 each
            // contribute ten verified seconds; only 110...200 is uncertain.
            #expect(current.snapshot.bounds.lower == 20)
            #expect(current.snapshot.bounds.upper == 110)
            #expect(current.forecast.goal == .uncertain)
            #expect(reopened.checkpoint?.observedAt == 210)
            let saved = try JournalV2Repository(url: url).load(now: 210)
            #expect(saved.catalog.observations[current.day.id] == [
                ObservationGap(start: 110, end: 200)
            ])
        }
    }

    @Test func `break does not create uncertain work and end break starts fresh checkpoint`() throws {
        try fixture { url, _ in
            var controller = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            _ = try controller.perform(.startBreak, sample: sample(110))
            #expect(controller.checkpoint == nil)
            var reopened = try JournalV2WorktimeController(url: url, sample: sample(200))
            let breakResult = try reopened.refresh(sample: sample(200))
            let duringBreak = try #require(breakResult)
            #expect(duringBreak.day.state == .onBreak)
            #expect(duringBreak.snapshot.bounds.lower == 10)
            #expect(duringBreak.snapshot.bounds.upper == 10)
            #expect(duringBreak.snapshot.recordedRest == 90)
            _ = try reopened.perform(.endBreak, sample: sample(210))
            #expect(reopened.checkpoint?.observedAt == 210)
            let active = try JournalV2Repository(url: url).load(now: 211)
            #expect(active.checkpoint?.observedAt == 210)
        }
    }

    @Test func `clock regression refuses writes and leaves stored checkpoint intact`() throws {
        try fixture { url, _ in
            var controller = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            _ = try controller.refresh(sample: sample(110))
            let original = try JournalV2Repository(url: url).load(now: 110)
            #expect(throws: ApplicationClockError.unreliableClock) {
                try controller.perform(.startBreak, sample: sample(109))
            }
            let disk = try JournalV2Repository(url: url).load(now: 110)
            #expect(disk.version == original.version)
            #expect(disk.catalog == original.catalog)
            #expect(disk.checkpoint == original.checkpoint)
        }
    }

    @Test func `other owner checkpoint update invalidates this controller`() throws {
        try fixture { url, _ in
            var controller = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let repository = try JournalV2Repository(url: url)
            let stale = try repository.load(now: 100)
            let day = try #require(stale.catalog.days.last)
            let updated = try repository.saveObservationCheckpoint(
                dayID: day.id, observedAt: 105, now: 105, matching: stale
            )
            #expect(updated.version == controller.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try controller.perform(.startBreak, sample: sample(105))
            }
            let saved = try repository.load(now: 110)
            #expect(saved.version == stale.version)
            #expect(saved.checkpoint == updated.checkpoint)
        }
    }

    @Test func `schema one database is never automatically replaced by schema two controller`() throws {
        try fixture { url, _ in
            _ = try CatalogRepository(url: url, createIfMissing: true)
            let original = try Data(contentsOf: url)
            #expect(throws: SnapshotStoreError.unsupportedSchema) {
                try JournalV2WorktimeController(
                    url: url, createIfMissing: true, sample: sample(100)
                )
            }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func `exports verify journal and cannot silently replace saved files`() throws {
        try fixture { url, root in
            var controller = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            _ = try controller.perform(
                .clockOut(confirmBreak: false), sample: sample(150)
            )
            let archive = root.appendingPathComponent("export.json")
            let csv = root.appendingPathComponent("export.csv")
            try controller.writeBackup(to: archive, now: 160)
            try controller.writeCSV(to: csv, now: 160)
            #expect(try JournalV2Backup.inspect(Data(contentsOf: archive), now: 160)
                .version == controller.version)
            #expect(try !Data(contentsOf: csv).isEmpty)
            #expect(throws: BackupFileError.self) {
                try controller.writeBackup(to: archive, now: 160)
            }
            #expect(try JournalV2Repository(url: url).load(now: 160).version == controller.version)
        }
    }
}
