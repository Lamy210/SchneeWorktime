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
        }
    }

    @Test func `latest and active day reject historical selection and stale confirmation`() throws {
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
}
