import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct ReviewRangeSelectionTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `selection accepts boundaries and rejects invalid offsets`() throws {
        let gap = ObservationGap(start: 110, end: 140)
        #expect(ReviewRangeSelection.duration(of: gap) == 30)
        #expect(try ReviewRangeSelection.selection(in: gap, startOffset: 0, endOffset: 30) == gap)
        let middle = try ReviewRangeSelection.selection(in: gap, startOffset: 10, endOffset: 20)
        #expect(middle == ObservationGap(start: 120, end: 130))
        let invalid: [(Int64, Int64)] = [(-1, 20), (10, 10), (20, 10), (0, 31)]
        for (start, end) in invalid {
            #expect(throws: HistoryReviewError.invalidSelection) {
                try ReviewRangeSelection.selection(in: gap, startOffset: start, endOffset: end)
            }
        }
    }

    @Test func `invalid and overflowed source ranges fail closed`() throws {
        for gap in [
            ObservationGap(start: 100, end: 100),
            ObservationGap(start: 100, end: 99),
            ObservationGap(start: Int64.min, end: Int64.max)
        ] {
            #expect(ReviewRangeSelection.duration(of: gap) == nil)
            #expect(throws: HistoryReviewError.invalidSelection) {
                try ReviewRangeSelection.selection(in: gap, startOffset: 0, endOffset: 1)
            }
        }
    }

    @Test func `partial rest review leaves both unselected ranges and one durable audit`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try controller.refresh(sample: sample(110))
            let currentResult = try controller.refresh(sample: sample(140))
            let current = try #require(currentResult)
            let gap = try #require(current.reviewableGaps.first)
            let selected = try ReviewRangeSelection.selection(in: gap, startOffset: 10, endOffset: 20)
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 141)
            let proposal = try controller.previewReview(selection: selected, classification: .rest, sample: sample(141))
            #expect(try repository.load(now: 141).version == before.version)
            #expect(proposal.after.snapshot.recordedRest == 10)
            let savedResult = try controller.commitReview(proposal, sample: sample(142))
            let saved = try #require(savedResult)
            let remaining = [ObservationGap(start: 110, end: 120), ObservationGap(start: 130, end: 140)]
            #expect(saved.reviewableGaps == remaining)
            #expect(saved.snapshot.recordedRest == 10)
            let stored = try repository.load(now: 142)
            #expect(stored.catalog.reviewAudit.count == 1)
            let reread = try WorktimeGlance(catalog: stored.catalog, now: 142)
            #expect(reread.reviewableGaps == remaining)
            #expect(!controller.isCurrent(proposal))
        }
    }
}
