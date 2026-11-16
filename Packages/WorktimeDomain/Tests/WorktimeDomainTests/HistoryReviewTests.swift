import Testing
@testable import WorktimeDomain

struct HistoryReviewTests {
    private let work = [RecordedInterval(start: 0, end: nil, kind: .work)]
    private let gaps = [ObservationGap(start: 20, end: 50), ObservationGap(start: 40, end: 70)]

    @Test func `confirm work removes only selected uncertainty`() throws {
        let result = try HistoryReview.resolve(
            intervals: work, uncertainty: gaps, selection: .init(start: 30, end: 60),
            classification: .work, now: 100
        )
        #expect(result.beforeIntervals == work)
        #expect(result.beforeUncertainty == gaps)
        #expect(result.afterIntervals == work)
        let expected = [ObservationGap(start: 20, end: 30), ObservationGap(start: 60, end: 70)]
        #expect(result.afterUncertainty == expected)
        let totals = try Timeline.snapshot(
            intervals: result.afterIntervals, uncertainty: result.afterUncertainty,
            now: 100, target: 80, expectedRest: 60
        )
        #expect(totals.bounds.lower == 80)
        #expect(totals.bounds.upper == 100)
        #expect(totals.bounds.attainment == .reached)
    }

    @Test func `rest consumes budget while gap does not`() throws {
        let classifications: [ReviewClassification] = [.rest, .gap]
        for classification in classifications {
            let result = try HistoryReview.resolve(
                intervals: work, uncertainty: gaps, selection: .init(start: 20, end: 70),
                classification: classification, now: 100
            )
            let totals = try Timeline.snapshot(
                intervals: result.afterIntervals, uncertainty: result.afterUncertainty,
                now: 100, target: 80, expectedRest: 60
            )
            #expect(result.afterUncertainty.isEmpty)
            #expect(totals.bounds.lower == 50)
            #expect(totals.bounds.upper == 50)
            #expect(totals.recordedRest == (classification == .rest ? 50 : 0))
            #expect(totals.remainingRest == (classification == .rest ? 10 : 60))
            #expect(result.reviewedAt == 100)
        }
    }

    @Test func `review through now keeps active interval open`() throws {
        let result = try HistoryReview.resolve(
            intervals: work, uncertainty: [.init(start: 70, end: 100)],
            selection: .init(start: 70, end: 100), classification: .rest, now: 100
        )
        #expect(result.afterIntervals.last == .init(start: 100, end: nil, kind: .work))
        let totals = try Timeline.snapshot(
            intervals: result.afterIntervals, uncertainty: result.afterUncertainty,
            now: 110, target: 100, expectedRest: 60
        )
        #expect(totals.bounds.lower == 80)
        #expect(totals.recordedRest == 30)
    }

    @Test func `closed work remains closed after review`() throws {
        let closed = [RecordedInterval(start: 0, end: 100, kind: .work)]
        let result = try HistoryReview.resolve(
            intervals: closed, uncertainty: [.init(start: 70, end: 100)],
            selection: .init(start: 70, end: 100), classification: .gap, now: 120
        )
        #expect(result.afterIntervals.last == .init(start: 70, end: 100, kind: .gap))
    }

    @Test func `review rejects uncovered and future ranges`() throws {
        #expect(throws: HistoryReviewError.notUnverifiedWork) {
            try HistoryReview.resolve(
                intervals: work, uncertainty: gaps, selection: .init(start: 10, end: 30),
                classification: .work, now: 100
            )
        }
        #expect(throws: HistoryReviewError.invalidSelection) {
            try HistoryReview.resolve(
                intervals: work, uncertainty: gaps, selection: .init(start: 90, end: 101),
                classification: .work, now: 100
            )
        }
        #expect(throws: HistoryReviewError.invalidSelection) {
            try HistoryReview.resolve(
                intervals: work, uncertainty: gaps, selection: .init(start: 30, end: 30),
                classification: .gap, now: 100
            )
        }
    }

    @Test func `duplicate review and review of actual rest are rejected`() throws {
        let result = try HistoryReview.resolve(
            intervals: work, uncertainty: gaps, selection: .init(start: 20, end: 70),
            classification: .rest, now: 100
        )
        #expect(throws: HistoryReviewError.notUnverifiedWork) {
            try HistoryReview.resolve(
                intervals: result.afterIntervals, uncertainty: result.afterUncertainty,
                selection: result.selection, classification: .work, now: 100
            )
        }
        #expect(throws: HistoryReviewError.notUnverifiedWork) {
            try HistoryReview.resolve(
                intervals: result.afterIntervals, uncertainty: gaps,
                selection: result.selection, classification: .work, now: 100
            )
        }
    }
}
