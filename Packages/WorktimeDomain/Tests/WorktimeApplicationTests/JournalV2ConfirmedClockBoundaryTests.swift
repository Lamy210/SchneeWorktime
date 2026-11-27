import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ConfirmedClockBoundaryTests {
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
        _ = try current.perform(.clockOut(confirmBreak: false), sample: sample(110))
        try run(url, current)
    }

    @Test func `confirmed clock in preserves summary preview and audit`() throws {
        try fixture { url, initial in
            var current = initial
            let context = current.workActionContext
            let day = try #require(context.day)
            let summary = ClockInSummarySelection(unit: .day, timeZoneID: "UTC")
            let intent = JournalV2ClockBoundaryIntent.clockIn(old: 100, new: 95, summary: summary)
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 111)
            let plan = try current.previewConfirmedClockBoundary(
                intent, day: day, matching: context, sample: sample(111)
            )
            #expect(plan.correction.summaryImpacts.count == 1)
            #expect(try repository.load(now: 111).catalog == before.catalog)
            let result = try current.commitConfirmedClockBoundary(plan, sample: sample(112))
            let saved = try repository.load(now: 112)
            #expect(result?.day.intervals.first?.start == 95)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedClockIn)
            #expect(saved.catalog.reviewAudit.last?.clockInRecord != nil)
            #expect(saved.checkpoint == nil)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try current.commitConfirmedClockBoundary(plan, sample: sample(113))
            }
        }
    }

    @Test func `confirmed historical clock out preserves active checkpoint after routine observation`() throws {
        try fixture { url, initial in
            var current = initial
            let old = try #require(current.workActionContext.day)
            _ = try current.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(120))
            let context = current.workActionContext
            let history = try current.recentHistory(now: 121)
            let selected = try current.historicalReviewContext(dayID: old.id, history: history, sample: sample(121))
            let plan = try current.previewConfirmedClockBoundary(
                .clockOut(old: 110, new: 111), day: selected.glance.day,
                historical: selected, matching: context, sample: sample(121)
            )
            _ = try current.refresh(sample: sample(130))
            let result = try current.commitConfirmedClockBoundary(plan, sample: sample(131))
            let saved = try JournalV2Repository(url: url).load(now: 131)
            #expect(result?.day == context.day)
            #expect(saved.catalog.days.first?.intervals.last?.end == 111)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedClockOut)
            #expect(saved.checkpoint?.dayID == context.day?.id)
            #expect(saved.checkpoint?.observedAt == 131)
        }
    }

    @Test func `clock boundary confirmation cannot be replayed in reopened session`() throws {
        try fixture { url, initial in
            let context = initial.workActionContext
            let day = try #require(context.day)
            let plan = try initial.previewConfirmedClockBoundary(
                .clockOut(old: 110, new: 111), day: day, matching: context, sample: sample(112)
            )
            var reopened = try JournalV2WorktimeController(url: url, createIfMissing: false, sample: sample(113))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 113)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try reopened.commitConfirmedClockBoundary(plan, sample: sample(114))
            }
            #expect(try repository.load(now: 114).catalog == before.catalog)
            #expect(try repository.load(now: 114).version == before.version)
        }
    }
}
