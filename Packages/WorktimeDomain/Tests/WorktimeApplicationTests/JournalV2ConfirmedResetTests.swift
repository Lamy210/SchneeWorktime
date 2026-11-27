import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ConfirmedResetTests {
    private func sample(_ at: Int64) throws -> ClockSample {
        try ClockSample(wall: at, uptime: Double(at))
    }

    private func fixture(_ run: (URL, JournalV2WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        var current = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        _ = try current.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
        try run(url, current)
    }

    @Test func `explicit consent clears active history and checkpoint in new epoch`() throws {
        try fixture { url, initial in
            var current = initial
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 101)
            let plan = try current.previewConfirmedReset(matching: current.workActionContext, sample: sample(101))
            #expect(plan.preview.hasActiveWorkday)
            #expect(plan.preview.workdays == 1)
            #expect(throws: JournalV2ConfirmedResetError.missingConsent) {
                try current.commitConfirmedReset(plan, consent: "削除 ", sample: sample(102))
            }
            #expect(try repository.load(now: 102).catalog == before.catalog)
            #expect(try repository.load(now: 102).checkpoint == before.checkpoint)
            try current.commitConfirmedReset(plan, consent: "削除", sample: sample(103))
            let saved = try repository.load(now: 103)
            #expect(saved.version.epoch != before.version.epoch)
            #expect(saved.version.revision == 0)
            #expect(saved.catalog.days.isEmpty)
            #expect(saved.catalog.reviewAudit.isEmpty)
            #expect(saved.checkpoint == nil)
            #expect(!current.isCurrent(plan))
        }
    }

    @Test func `routine checkpoint advancement invalidates destructive confirmation`() throws {
        try fixture { url, initial in
            var current = initial
            let plan = try current.previewConfirmedReset(matching: current.workActionContext, sample: sample(101))
            _ = try current.refresh(sample: sample(110))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 110)
            #expect(before.version == plan.preview.version)
            #expect(!current.isCurrent(plan))
            #expect(throws: JournalV2ConfirmedResetError.staleConfirmation) {
                try current.commitConfirmedReset(plan, consent: "削除", sample: sample(111))
            }
            #expect(try repository.load(now: 111).checkpoint == before.checkpoint)
            #expect(try repository.load(now: 111).version == before.version)
        }
    }

    @Test func `external checkpoint change is rejected by complete repository CAS`() throws {
        try fixture { url, initial in
            var current = initial
            let plan = try current.previewConfirmedReset(matching: current.workActionContext, sample: sample(101))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 101)
            let day = try #require(before.catalog.days.last)
            let external = try repository.saveObservationCheckpoint(
                dayID: day.id, observedAt: 102, now: 102, matching: before
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try current.commitConfirmedReset(plan, consent: "削除", sample: sample(103))
            }
            #expect(try repository.load(now: 103).checkpoint == external.checkpoint)
            #expect(try repository.load(now: 103).catalog == before.catalog)
        }
    }
}
