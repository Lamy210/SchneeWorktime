import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2WorktimeMaintenanceTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func fixture(
        _ body: (URL, URL, JournalV2WorktimeController) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("live")
        let preserve = root.appendingPathComponent("preserve")
        for directory in [root, live, preserve] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let database = live.appendingPathComponent("worktime.sqlite")
        let controller = try JournalV2WorktimeController(
            url: database, createIfMissing: true, sample: sample(100)
        )
        try body(database, preserve, controller)
    }

    private func endedDay(
        _ controller: inout JournalV2WorktimeController, at time: Int64
    ) throws -> UUID {
        let id = UUID()
        _ = try controller.perform(
            .clockIn(id: id, profile: WorkdayProfile()), sample: sample(time)
        )
        _ = try controller.perform(
            .clockOut(confirmBreak: false), sample: sample(time + 10)
        )
        return id
    }

    @Test func `reset preview is read only and successful commit atomically clears checkpoint`() throws {
        try fixture { url, _, initial in
            var controller = initial
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 100)
            #expect(before.checkpoint?.observedAt == 100)
            let preview = try controller.previewReset(sample: sample(110))
            #expect(preview.version == before.version)
            #expect(preview.workdays == 1)
            #expect(preview.hasActiveWorkday)
            let unchanged = try repository.load(now: 110)
            #expect(unchanged.version == before.version)
            #expect(unchanged.checkpoint == before.checkpoint)
            #expect(unchanged.catalog == before.catalog)

            try controller.commitReset(preview, sample: sample(110))
            #expect(!controller.isCurrent(preview))
            #expect(controller.version.epoch != before.version.epoch)
            #expect(controller.version.revision == 0)
            #expect(controller.checkpoint == nil)
            let emptyResult = try controller.refresh(sample: sample(110))
            #expect(emptyResult?.day == nil)
            let cleared = try JournalV2Repository(url: url).load(now: 110)
            #expect(cleared.version == controller.version)
            #expect(cleared.catalog.days.isEmpty)
            #expect(cleared.catalog.reviewAudit.isEmpty)
            #expect(cleared.checkpoint == nil)

            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(120)
            )
            #expect(controller.version.epoch == cleared.version.epoch)
            #expect(controller.version.revision == 1)
        }
    }

    @Test func `checkpoint-only concurrent change prevents confirmed deletion`() throws {
        try fixture { url, _, initial in
            var controller = initial
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let preview = try controller.previewReset(sample: sample(105))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 105)
            let day = try #require(before.catalog.days.last)
            let updated = try repository.saveObservationCheckpoint(
                dayID: day.id, observedAt: 105, now: 105, matching: before
            )
            #expect(controller.isCurrent(preview))
            #expect(throws: JournalMigrationError.verificationFailed) {
                try controller.commitReset(preview, sample: sample(110))
            }
            let current = try repository.load(now: 110)
            #expect(current.version == before.version)
            #expect(current.catalog == before.catalog)
            #expect(current.checkpoint == updated.checkpoint)
        }
    }

    @Test func `reset never silently resurrects a previous epoch archive`() throws {
        try fixture { url, preserve, initial in
            var controller = initial
            _ = try endedDay(&controller, at: 100)
            let archive = preserve.appendingPathComponent("before-reset.json")
            try controller.writeBackup(to: archive, now: 120)
            let oldVersion = controller.version
            let preview = try controller.previewReset(sample: sample(120))
            try controller.commitReset(preview, sample: sample(120))
            let fresh = try JournalV2Repository(url: url).load(now: 130)
            #expect(fresh.version == controller.version)
            #expect(fresh.version.epoch != oldVersion.epoch)
            #expect(fresh.catalog.days.isEmpty)
            #expect(FileManager.default.fileExists(atPath: archive.path))
            #expect(throws: CatalogRollbackError.differentGeneration) {
                try controller.previewRollback(file: archive, sample: sample(130))
            }
            let restarted = try JournalV2WorktimeController(url: url, sample: sample(140))
            #expect(restarted.version == controller.version)
        }
    }

    @Test func `rollback preserves current data before replacing ended prefix`() throws {
        try fixture { url, preserve, initial in
            var controller = initial
            let firstID = try endedDay(&controller, at: 100)
            let older = preserve.appendingPathComponent("older.json")
            try controller.writeBackup(to: older, now: 120)
            _ = try endedDay(&controller, at: 200)
            let latest = try JournalV2Repository(url: url).load(now: 220)
            let preview = try controller.previewRollback(file: older, sample: sample(220))
            #expect(preview.currentVersion == latest.version)
            #expect(preview.currentDays == 2)
            #expect(preview.restoredDays == 1)
            #expect(try JournalV2Repository(url: url).load(now: 220).catalog.days.count == 2)

            let preserved = preserve.appendingPathComponent("current.json")
            try controller.commitRollback(
                preview, preserveCurrentAt: preserved, sample: sample(230)
            )
            #expect(!controller.isCurrent(preview))
            #expect(controller.version.epoch != latest.version.epoch)
            #expect(controller.version.revision == 2)
            #expect(controller.checkpoint == nil)
            let restoredResult = try controller.refresh(sample: sample(230))
            let restored = try #require(restoredResult)
            #expect(restored.day.id == firstID)
            let reopened = try JournalV2Repository(url: url).load(now: 240)
            #expect(reopened.catalog.days.count == 1)
            #expect(reopened.version == controller.version)
            let currentArchive = try BackupFile.load(
                preserved, maxBytes: JournalV2Backup.maxBytes
            )
            #expect(try JournalV2Backup.inspect(currentArchive, now: 240).version == latest.version)
        }
    }

    @Test func `stale rollback proposal never publishes a preservation backup`() throws {
        try fixture { url, preserve, initial in
            var controller = initial
            _ = try endedDay(&controller, at: 100)
            let older = preserve.appendingPathComponent("older.json")
            try controller.writeBackup(to: older, now: 120)
            _ = try endedDay(&controller, at: 200)
            let preview = try controller.previewRollback(file: older, sample: sample(220))
            _ = try endedDay(&controller, at: 230)
            let backup = preserve.appendingPathComponent("should-not-exist.json")
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.commitRollback(
                    preview, preserveCurrentAt: backup, sample: sample(260)
                )
            }
            #expect(!FileManager.default.fileExists(atPath: backup.path))
            #expect(try JournalV2Repository(url: url).load(now: 260).catalog.days.count == 3)
        }
    }

    @Test func `rollback refuses an active workday and leaves source unchanged`() throws {
        try fixture { url, preserve, initial in
            var controller = initial
            _ = try endedDay(&controller, at: 100)
            let older = preserve.appendingPathComponent("older.json")
            try controller.writeBackup(to: older, now: 120)
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(200)
            )
            let before = try JournalV2Repository(url: url).load(now: 210)
            #expect(throws: CatalogRollbackError.activeWorkday) {
                try controller.previewRollback(file: older, sample: sample(210))
            }
            let after = try JournalV2Repository(url: url).load(now: 210)
            #expect(after.version == before.version)
            #expect(after.checkpoint == before.checkpoint)
            #expect(after.catalog == before.catalog)
        }
    }

    @Test func `clock regression rejects maintenance without changing the live epoch`() throws {
        try fixture { url, _, initial in
            var controller = initial
            _ = try endedDay(&controller, at: 100)
            let before = try JournalV2Repository(url: url).load(now: 110)
            #expect(throws: ApplicationClockError.unreliableClock) {
                try controller.previewReset(sample: sample(99))
            }
            let proposal = try controller.previewReset(sample: sample(110))
            #expect(throws: ApplicationClockError.unreliableClock) {
                try controller.commitReset(proposal, sample: sample(99))
            }
            #expect(try JournalV2Repository(url: url).load(now: 110).version == before.version)
        }
    }
}
