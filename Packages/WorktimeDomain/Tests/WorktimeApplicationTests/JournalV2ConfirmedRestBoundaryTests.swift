import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ConfirmedRestBoundaryTests {
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
        _ = try current.perform(.startBreak, sample: sample(110))
        _ = try current.perform(.endBreak, sample: sample(120))
        try run(url, current)
    }

    @Test func `confirmed rest start preserves recorded intent after routine observation`() throws {
        try fixture { url, initial in
            var current = initial
            let displayed = current.workActionContext
            let day = try #require(displayed.day)
            let intent = JournalV2RestBoundaryIntent(boundary: .start, old: 110, new: 105)
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 121)
            let plan = try current.previewConfirmedRestBoundary(intent, day: day, matching: displayed, sample: sample(121))
            #expect(try repository.load(now: 121).catalog == before.catalog)
            for instant in stride(from: Int64(130), through: 180, by: 10) {
                _ = try current.refresh(sample: sample(instant))
            }
            let result = try current.commitConfirmedRestBoundary(plan, sample: sample(181))
            let saved = try repository.load(now: 181)
            #expect(result?.snapshot.recordedRest == 15)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedRestStart)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(saved.checkpoint?.observedAt == 181)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try current.commitConfirmedRestBoundary(plan, sample: sample(182))
            }
            #expect(try repository.load(now: 182).catalog == saved.catalog)
        }
    }

    @Test func `rest end correction rejects external checkpoint without changing audit`() throws {
        try fixture { url, initial in
            var current = initial
            let displayed = current.workActionContext
            let day = try #require(displayed.day)
            let intent = JournalV2RestBoundaryIntent(boundary: .end, old: 120, new: 115)
            let plan = try current.previewConfirmedRestBoundary(intent, day: day, matching: displayed, sample: sample(121))
            _ = try current.refresh(sample: sample(130))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 130)
            let other = try repository.saveObservationCheckpoint(
                dayID: day.id, observedAt: 131, now: 131, matching: before
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try current.commitConfirmedRestBoundary(plan, sample: sample(132))
            }
            let saved = try repository.load(now: 132)
            #expect(saved.catalog == other.catalog)
            #expect(saved.checkpoint == other.checkpoint)
            #expect(saved.version == other.version)
        }
    }

    @Test func `rest end correction rejects new observation gap and invalid boundary`() throws {
        try fixture { url, initial in
            var current = initial
            let displayed = current.workActionContext
            let day = try #require(displayed.day)
            let invalid = JournalV2RestBoundaryIntent(boundary: .end, old: 120, new: 110)
            #expect(throws: RestEndCorrectionError.invalidBoundary) {
                try current.previewConfirmedRestBoundary(invalid, day: day, matching: displayed, sample: sample(121))
            }
            let valid = JournalV2RestBoundaryIntent(boundary: .end, old: 120, new: 115)
            let plan = try current.previewConfirmedRestBoundary(valid, day: day, matching: displayed, sample: sample(121))
            _ = try current.refresh(sample: sample(150))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 151)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try current.commitConfirmedRestBoundary(plan, sample: sample(151))
            }
            #expect(try repository.load(now: 151).catalog == before.catalog)
            #expect(try repository.load(now: 151).checkpoint == before.checkpoint)
        }
    }
}
