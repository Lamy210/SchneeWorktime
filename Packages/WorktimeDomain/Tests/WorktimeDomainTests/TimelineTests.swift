import Testing
@testable import WorktimeDomain

struct TimelineTests {
    @Test func `overlapping observations count once and only within work`() throws {
        let intervals = [
            RecordedInterval(start: 0, end: 100, kind: .work),
            RecordedInterval(start: 100, end: 130, kind: .rest),
            RecordedInterval(start: 130, end: nil, kind: .work)
        ]
        let gaps = [ObservationGap(start: 80, end: 140), ObservationGap(start: 90, end: 150)]
        let result = try Timeline.snapshot(intervals: intervals, uncertainty: gaps, now: 200,
                                           target: 140, expectedRest: 60)
        #expect(result.bounds.lower == 130)
        #expect(result.bounds.upper == 170)
        #expect(result.bounds.attainment == .possible)
        #expect(result.recordedRest == 30)
        #expect(result.remainingRest == 30)
    }

    @Test func `historical rest does not consume anchored plan`() throws {
        let intervals = [
            RecordedInterval(start: 0, end: 20, kind: .rest),
            RecordedInterval(start: 20, end: 100, kind: .work),
            RecordedInterval(start: 100, end: nil, kind: .rest)
        ]
        let plan = RestPlan(anchor: 110, remainingAtAnchor: 30)
        let result = try Timeline.snapshot(intervals: intervals, uncertainty: [], now: 120,
                                           target: 100, expectedRest: 60, override: plan)
        #expect(result.recordedRest == 40)
        #expect(result.remainingRest == 20)
        #expect(result.bounds.lower == 80)
        let later = try Timeline.snapshot(intervals: intervals, uncertainty: [], now: 150,
                                          target: 100, expectedRest: 60, override: plan)
        #expect(later.remainingRest == 0)
    }

    @Test func `nonworking gap does not consume expected rest`() throws {
        let intervals = [
            RecordedInterval(start: 0, end: 100, kind: .work),
            RecordedInterval(start: 100, end: 160, kind: .gap),
            RecordedInterval(start: 160, end: nil, kind: .work)
        ]
        let result = try Timeline.snapshot(intervals: intervals, uncertainty: [], now: 200,
                                           target: 150, expectedRest: 60)
        #expect(result.bounds.lower == 140)
        #expect(result.recordedRest == 0)
        #expect(result.remainingRest == 60)
    }

    @Test func `open work at clock in has zero duration`() throws {
        let intervals = [RecordedInterval(start: 100, end: nil, kind: .work)]
        let result = try Timeline.snapshot(intervals: intervals, uncertainty: [], now: 100,
                                           target: 420, expectedRest: 60)
        #expect(result.bounds.lower == 0)
        #expect(result.bounds.attainment == .notReached)
    }

    @Test func `invalid timelines fail rather than being guessed`() throws {
        let overlap = [
            RecordedInterval(start: 0, end: 90, kind: .work),
            RecordedInterval(start: 70, end: 100, kind: .rest)
        ]
        #expect(throws: WorktimeError.overlappingIntervals) {
            try Timeline.snapshot(intervals: overlap, uncertainty: [], now: 100,
                                  target: 100, expectedRest: 60)
        }
        let open = [
            RecordedInterval(start: 0, end: nil, kind: .work),
            RecordedInterval(start: 70, end: nil, kind: .rest)
        ]
        #expect(throws: WorktimeError.invalidInterval) {
            try Timeline.snapshot(intervals: open, uncertainty: [], now: 100,
                                  target: 100, expectedRest: 60)
        }
    }
}
