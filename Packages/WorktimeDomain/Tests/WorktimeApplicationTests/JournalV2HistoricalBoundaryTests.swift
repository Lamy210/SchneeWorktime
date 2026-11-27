import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2HistoricalBoundaryTests {
    private func sample(_ at: Int64) throws -> ClockSample {
        try ClockSample(wall: at, uptime: Double(at))
    }

    private func fixture(_ run: (URL, JournalV2WorktimeController, UUID) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        var current = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        let old = UUID()
        _ = try current.perform(.clockIn(id: old, profile: WorkdayProfile()), sample: sample(100))
        _ = try current.perform(.startBreak, sample: sample(110))
        _ = try current.perform(.endBreak, sample: sample(120))
        _ = try current.perform(.clockOut(confirmBreak: false), sample: sample(130))
        _ = try current.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(140))
        try run(url, current, old)
    }

    @Test func `historical rest correction invalidates sibling editor and preserves active day`() throws {
        try fixture { url, initial, old in
            var current = initial
            let context = current.workActionContext
            let history = try current.recentHistory(now: 141)
            let selected = try current.historicalReviewContext(dayID: old, history: history, sample: sample(141))
            let rest = JournalV2RestBoundaryIntent(boundary: .start, old: 110, new: 105)
            let plan = try current.previewConfirmedRestBoundary(
                rest, day: selected.glance.day, historical: selected, matching: context, sample: sample(141)
            )
            let sibling = try current.previewConfirmedClockBoundary(
                .clockOut(old: 130, new: 131), day: selected.glance.day,
                historical: selected, matching: context, sample: sample(141)
            )
            _ = try current.refresh(sample: sample(150))
            let result = try current.commitConfirmedRestBoundary(plan, sample: sample(151))
            let repository = try JournalV2Repository(url: url)
            let saved = try repository.load(now: 151)
            #expect(result?.day == context.day)
            #expect(saved.checkpoint?.dayID == context.day?.id)
            #expect(saved.checkpoint?.observedAt == 151)
            #expect(try saved.catalog.snapshot(dayID: old, now: 151).recordedRest == 15)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedRestStart)
            #expect(!current.isCurrent(selected))
            #expect(!current.isCurrent(history))
            #expect(!current.isCurrent(sibling))
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try current.commitConfirmedClockBoundary(sibling, sample: sample(152))
            }
            #expect(try repository.load(now: 152).catalog == saved.catalog)
        }
    }

    @Test func `fresh history selection allows another boundary correction during current break`() throws {
        try fixture { url, initial, old in
            var current = initial
            _ = try current.perform(.startBreak, sample: sample(145))
            let history = try current.recentHistory(now: 146)
            let selected = try current.historicalReviewContext(dayID: old, history: history, sample: sample(146))
            let context = current.workActionContext
            let rest = JournalV2RestBoundaryIntent(boundary: .end, old: 120, new: 125)
            let plan = try current.previewConfirmedRestBoundary(
                rest, day: selected.glance.day, historical: selected, matching: context, sample: sample(146)
            )
            _ = try current.commitConfirmedRestBoundary(plan, sample: sample(147))
            let nextHistory = try current.recentHistory(now: 148)
            let next = try current.historicalReviewContext(dayID: old, history: nextHistory, sample: sample(148))
            let summary = ClockInSummarySelection(unit: .day, timeZoneID: "UTC")
            let intent = JournalV2ClockBoundaryIntent.clockIn(old: 100, new: 95, summary: summary)
            let second = try current.previewConfirmedClockBoundary(
                intent, day: next.glance.day, historical: next, matching: current.workActionContext,
                sample: sample(148)
            )
            #expect(second.correction.summaryImpacts.count == 1)
            let result = try current.commitConfirmedClockBoundary(second, sample: sample(149))
            let saved = try JournalV2Repository(url: url).load(now: 149)
            #expect(result?.day == context.day)
            #expect(result?.day.state == .onBreak)
            #expect(saved.checkpoint == nil)
            #expect(saved.catalog.days.first?.intervals.first?.start == 95)
            #expect(try saved.catalog.snapshot(dayID: old, now: 149).recordedRest == 15)
            #expect(saved.catalog.reviewAudit.map(\.origin) == [.recordedRestEnd, .recordedClockIn])
        }
    }
}
