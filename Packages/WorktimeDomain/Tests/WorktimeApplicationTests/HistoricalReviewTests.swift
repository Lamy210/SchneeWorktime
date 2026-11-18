import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct HistoricalReviewTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withHistory(_ body: (URL, inout WorktimeController, UUID, UUID) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worktime.sqlite")
        var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        let first = UUID()
        let latest = UUID()
        _ = try controller.perform(.clockIn(id: first, profile: WorkdayProfile()), sample: sample(100))
        _ = try controller.refresh(sample: sample(110))
        _ = try controller.refresh(sample: sample(140))
        _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(150))
        _ = try controller.perform(.clockIn(id: latest, profile: WorkdayProfile()), sample: sample(200))
        _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(210))
        try body(url, &controller, first, latest)
    }

    @Test func `historical partial correction preserves latest day and records original day audit`() throws {
        try withHistory { url, controller, first, latest in
            let history = try controller.recentHistory(now: 220)
            #expect(controller.isCurrent(history))
            let context = try controller.historicalReviewContext(dayID: first, history: history, sample: sample(220))
            let gap = try #require(context.glance.reviewableGaps.first)
            let selection = ObservationGap(start: 120, end: 130)
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 220)
            let proposal = try controller.previewHistoricalReview(
                context, selection: selection, source: gap, classification: .rest, sample: sample(221)
            )
            #expect(proposal.before.day.id == first)
            #expect(proposal.after.snapshot.recordedRest == 10)
            #expect(try repository.load(now: 221).version == before.version)
            let current = try controller.commitReview(proposal, sample: sample(222))
            #expect(current?.day.id == latest)
            #expect(current?.day == before.catalog.days.last)
            let saved = try repository.load(now: 222)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(saved.catalog.reviewAudit.first?.dayID == first)
            #expect(saved.catalog.observations[first] == [
                ObservationGap(start: 110, end: 120), ObservationGap(start: 130, end: 140)
            ])
            #expect(!controller.isCurrent(context))
            #expect(!controller.isCurrent(proposal))
            #expect(!controller.isCurrent(history))
            let refreshed = try controller.recentHistory(now: 222)
            #expect(controller.isCurrent(refreshed))
            #expect(refreshed.rows.first(where: { $0.id == first })?.rest == 10)
        }
    }

    @Test func `previous history page is stale after database generation changes`() throws {
        try withHistory { url, controller, _, _ in
            let history = try controller.recentHistory(now: 220)
            #expect(controller.isCurrent(history))
            let proposal = try controller.previewReset(sample: sample(221))
            try controller.commitReset(proposal, sample: sample(222))
            let reopened = try WorktimeController(url: url, sample: sample(223))
            #expect(!reopened.isCurrent(history))
            let empty = try reopened.recentHistory(now: 223)
            #expect(reopened.isCurrent(empty))
            #expect(empty.rows.isEmpty)
        }
    }

    @Test func `latest day and stale selection reject historical confirmation`() throws {
        try withHistory { url, controller, first, latest in
            let history = try controller.recentHistory(now: 220)
            #expect(throws: HistoricalReviewError.staleContext) {
                try controller.historicalReviewContext(dayID: latest, history: history, sample: sample(220))
            }
            let context = try controller.historicalReviewContext(dayID: first, history: history, sample: sample(220))
            let gap = try #require(context.glance.reviewableGaps.first)
            let proposal = try controller.previewHistoricalReview(
                context, selection: gap, source: gap, classification: .work, sample: sample(221)
            )
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(222))
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 222)
            #expect(throws: HistoricalReviewError.staleContext) {
                try controller.historicalReviewContext(dayID: first, history: history, sample: sample(223))
            }
            #expect(throws: HistoricalReviewError.staleContext) {
                try controller.previewHistoricalReview(
                    context, selection: gap, source: gap, classification: .work, sample: sample(223)
                )
            }
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.commitReview(proposal, sample: sample(223))
            }
            #expect(try repository.load(now: 223).version == before.version)
        }
    }

    @Test(arguments: [false, true])
    func `historical correction during active work preserves active day`(onBreak: Bool) throws {
        try withHistory { url, controller, first, _ in
            let activeID = UUID()
            _ = try controller.perform(.clockIn(id: activeID, profile: WorkdayProfile()), sample: sample(220))
            if onBreak {
                _ = try controller.perform(.startBreak, sample: sample(221))
            }
            let history = try controller.recentHistory(now: 222)
            let context = try controller.historicalReviewContext(dayID: first, history: history, sample: sample(222))
            let gap = try #require(context.glance.reviewableGaps.first)
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 222)
            let proposal = try controller.previewHistoricalReview(
                context, selection: gap, source: gap, classification: .rest, sample: sample(223)
            )
            #expect(proposal.after.day.id == first)
            #expect(try repository.load(now: 223).version == before.version)
            let current = try controller.commitReview(proposal, sample: sample(224))
            let saved = try repository.load(now: 224)
            #expect(saved.catalog.activeID == activeID)
            #expect(saved.catalog.days.last == before.catalog.days.last)
            #expect(current?.day == before.catalog.days.last)
            #expect(saved.catalog.reviewAudit.last?.dayID == first)
            #expect(saved.catalog.observations[activeID] == before.catalog.observations[activeID])
            #expect(!controller.isCurrent(context))
        }
    }

    @Test func `new observation gap during historical confirmation invalidates proposal`() throws {
        try withHistory { url, controller, first, _ in
            let activeID = UUID()
            _ = try controller.perform(.clockIn(id: activeID, profile: WorkdayProfile()), sample: sample(220))
            let history = try controller.recentHistory(now: 221)
            let context = try controller.historicalReviewContext(dayID: first, history: history, sample: sample(221))
            let gap = try #require(context.glance.reviewableGaps.first)
            let proposal = try controller.previewHistoricalReview(
                context, selection: gap, source: gap, classification: .rest, sample: sample(222)
            )
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 222)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.commitReview(proposal, sample: sample(240))
            }
            let saved = try repository.load(now: 240)
            #expect(saved.catalog.activeID == activeID)
            #expect(saved.catalog.reviewAudit == before.catalog.reviewAudit)
            #expect(saved.catalog.days.first == before.catalog.days.first)
            #expect(saved.catalog.observations[activeID] == [ObservationGap(start: 220, end: 240)])
        }
    }
}
