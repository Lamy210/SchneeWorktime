import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ConfirmedRollbackTests {
    private func sample(_ at: Int64) throws -> ClockSample {
        try ClockSample(wall: at, uptime: Double(at))
    }

    private func fixture(
        _ run: (URL, URL, JournalV2WorktimeController, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("live")
        let preserve = root.appendingPathComponent("preserve")
        for directory in [root, live, preserve] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let url = live.appendingPathComponent("worktime.sqlite")
        var current = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        _ = try current.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
        _ = try current.perform(.clockOut(confirmBreak: false), sample: sample(110))
        let older = preserve.appendingPathComponent("older.json")
        try current.writeBackup(to: older, now: 120)
        _ = try current.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(200))
        _ = try current.perform(.clockOut(confirmBreak: false), sample: sample(210))
        try run(url, preserve, current, older)
    }

    @Test func `confirmed rollback preserves captured candidate and full current generation`() throws {
        try fixture { url, preserve, initial, older in
            var current = initial
            let context = current.workActionContext
            let before = try JournalV2Repository(url: url).load(now: 220)
            let plan = try current.previewConfirmedRollback(file: older, matching: context, sample: sample(220))
            #expect(plan.proposal.restoredDays == 1)
            let second = try current.previewConfirmedRollback(file: older, matching: context, sample: sample(220))
            #expect(second.id != plan.id)
            #expect(second.context == plan.context)
            #expect(try JournalV2Repository(url: url).load(now: 220).catalog == before.catalog)
            // Replacing the selected file cannot substitute a different candidate.
            try FileManager.default.removeItem(at: older)
            try current.writeBackup(to: older, now: 220)
            let destination = preserve.appendingPathComponent("current.json")
            try current.commitConfirmedRollback(plan, preserveCurrentAt: destination, sample: sample(230))
            let saved = try JournalV2Repository(url: url).load(now: 230)
            #expect(saved.catalog.days.count == 1)
            #expect(saved.version.epoch != before.version.epoch)
            #expect(saved.checkpoint == nil)
            let data = try BackupFile.load(destination, maxBytes: JournalV2Backup.maxBytes)
            #expect(try JournalV2Backup.inspect(data, now: 230).version == before.version)
            #expect(!current.isCurrent(plan))
        }
    }

    @Test func `reopened session rejects old rollback without preservation side effect`() throws {
        try fixture { url, preserve, initial, older in
            let plan = try initial.previewConfirmedRollback(
                file: older, matching: initial.workActionContext, sample: sample(220)
            )
            var current = try JournalV2WorktimeController(url: url, sample: sample(221))
            let destination = preserve.appendingPathComponent("unexpected.json")
            let before = try JournalV2Repository(url: url).load(now: 221)
            #expect(throws: JournalV2WorkActionError.staleContext) {
                try current.commitConfirmedRollback(plan, preserveCurrentAt: destination, sample: sample(222))
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try JournalV2Repository(url: url).load(now: 222).version == before.version)
            #expect(try JournalV2Repository(url: url).load(now: 222).catalog == before.catalog)
        }
    }
}
