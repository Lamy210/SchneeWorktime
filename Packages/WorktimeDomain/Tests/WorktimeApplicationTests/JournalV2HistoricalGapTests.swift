import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2HistoricalGapTests {
    private func sample(_ time: Int64) throws -> ClockSample {
        try ClockSample(wall: time, uptime: Double(time))
    }

    private func fixture(_ run: (URL, JournalV2WorktimeController, HistoricalReviewContext) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        var controller = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        let id = UUID()
        _ = try controller.perform(.clockIn(id: id, profile: WorkdayProfile()), sample: sample(100))
        _ = try controller.refresh(sample: sample(110))
        _ = try controller.refresh(sample: sample(140))
        _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(145))
        _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(150))
        let history = try controller.recentHistory(now: 151)
        let selected = try controller.historicalReviewContext(dayID: id, history: history, sample: sample(151))
        try run(url, controller, selected)
    }

    @Test func `historical partial correction survives routine observation and preserves active day`() throws {
        try fixture { url, initial, historical in
            var current = initial
            let gap = try #require(historical.glance.reviewableGaps.first)
            let selection = ObservationGap(start: 120, end: 130)
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 151)
            let proposal = try current.previewHistoricalGap(
                historical: historical, source: gap, selection: selection,
                classification: .rest, sample: sample(151)
            )
            #expect(try repository.load(now: 151).catalog == before.catalog)
            for time in stride(from: Int64(160), through: 210, by: 10) {
                _ = try current.refresh(sample: sample(time))
            }
            let result = try current.commitHistoricalGap(proposal, sample: sample(211))
            let saved = try repository.load(now: 211)
            #expect(result?.day == before.catalog.days.last)
            #expect(saved.catalog.activeID == before.catalog.activeID)
            #expect(saved.catalog.days.last == before.catalog.days.last)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(saved.catalog.reviewAudit.last?.dayID == historical.glance.day.id)
            #expect(saved.catalog.reviewAudit.last?.review.selection == selection)
            #expect(saved.checkpoint?.dayID == before.catalog.activeID)
            #expect(saved.checkpoint?.observedAt == 211)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try current.commitHistoricalGap(proposal, sample: sample(212))
            }
        }
    }

    @Test func `historical correction on break never creates a working checkpoint`() throws {
        try fixture { url, initial, historical in
            var current = initial
            _ = try current.perform(.startBreak, sample: sample(152))
            let history = try current.recentHistory(now: 153)
            let selected = try current.historicalReviewContext(
                dayID: historical.glance.day.id, history: history, sample: sample(153)
            )
            let gap = try #require(selected.glance.reviewableGaps.first)
            let proposal = try current.previewHistoricalGap(
                historical: selected, source: gap, selection: gap, classification: .work, sample: sample(153)
            )
            let result = try current.commitHistoricalGap(proposal, sample: sample(154))
            let saved = try JournalV2Repository(url: url).load(now: 154)
            #expect(result?.day.state == .onBreak)
            #expect(saved.checkpoint == nil)
            #expect(saved.catalog.reviewAudit.count == 1)
        }
    }

    @Test func `historical proposal rejects external checkpoint and new observation gap`() throws {
        try fixture { url, initial, historical in
            var current = initial
            let gap = try #require(historical.glance.reviewableGaps.first)
            let proposal = try current.previewHistoricalGap(
                historical: historical, source: gap, selection: gap, classification: .gap, sample: sample(151)
            )
            _ = try current.refresh(sample: sample(160))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 160)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try current.commitHistoricalGap(proposal, sample: sample(180))
            }
            let day = try #require(before.catalog.days.last)
            let external = try repository.saveObservationCheckpoint(
                dayID: day.id, observedAt: 161, now: 161, matching: before
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try current.commitHistoricalGap(proposal, sample: sample(162))
            }
            let saved = try repository.load(now: 162)
            #expect(saved.version == external.version)
            #expect(saved.catalog == external.catalog)
            #expect(saved.checkpoint == external.checkpoint)
        }
    }
}
