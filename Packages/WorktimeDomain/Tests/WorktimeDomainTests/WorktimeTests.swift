import Testing
@testable import WorktimeDomain

struct WorktimeTests {
    private func m(_ minute: Int64) -> Int64 { minute * 60 }

    @Test func attainmentAndCrossing() throws {
        let spans = [
            WorkSpan(start: 0, end: m(300), verified: true),
            WorkSpan(start: m(300), end: m(360), verified: false),
            WorkSpan(start: m(360), end: m(480), verified: true),
        ]
        let result = try Worktime.bounds(spans: spans, now: m(480), target: m(420))
        #expect(result.lower == m(420))
        #expect(result.upper == m(480))
        #expect(result.attainment == .reached)
        #expect(result.crossing == .range(m(420)...m(480)))
    }

    @Test func possibleNotConfirmed() throws {
        let spans = [WorkSpan(start: 0, end: m(360), verified: true),
                     WorkSpan(start: m(360), end: m(420), verified: false)]
        let result = try Worktime.bounds(spans: spans, now: m(420), target: m(420))
        #expect(result.attainment == .possible)
        #expect(result.crossing == .unavailable)
    }

    @Test func exactBeforeLaterUncertainty() throws {
        let spans = [WorkSpan(start: 0, end: m(420), verified: true),
                     WorkSpan(start: m(420), end: m(480), verified: false)]
        let result = try Worktime.bounds(spans: spans, now: m(480), target: m(420))
        #expect(result.crossing == .exact(m(420)))
    }

    @Test func rejectOverlapAndFuture() throws {
        #expect(throws: WorktimeError.overlappingIntervals) {
            try Worktime.bounds(spans: [.init(start: 0, end: 60, verified: true),
                                       .init(start: 30, end: 90, verified: false)], now: 90, target: 60)
        }
        #expect(throws: WorktimeError.invalidInterval) {
            try Worktime.bounds(spans: [.init(start: 0, end: 61, verified: true)], now: 60, target: 60)
        }
    }

    @Test func impossibleRestAndLeaveNow() throws {
        let bounds = try Worktime.bounds(spans: [.init(start: 0, end: m(400), verified: true)], now: m(400), target: m(420))
        #expect(try Worktime.preview(bounds: bounds, now: m(400), candidate: m(450), remainingRest: m(60), state: .working) == .infeasible)
        #expect(try Worktime.preview(bounds: bounds, now: m(400), candidate: m(450), remainingRest: m(30), state: .working) == .feasible(worked: m(420)...m(420), futureRest: m(30)))
        #expect(try Worktime.preview(bounds: bounds, now: m(400), candidate: m(400), remainingRest: m(60), state: .working) == .feasible(worked: m(400)...m(400), futureRest: 0))
        #expect(try Worktime.preview(bounds: bounds, now: m(400), candidate: m(399), remainingRest: 0, state: .working) == .invalidCandidate)
    }

    @Test func activeBreakConsumesBudgetOnce() throws {
        let bounds = try Worktime.bounds(spans: [.init(start: 0, end: m(30), verified: true)], now: m(50), target: m(420))
        #expect(try Worktime.preview(bounds: bounds, now: m(50), candidate: m(480), remainingRest: m(40), state: .onBreak(returnAt: m(90))) == .feasible(worked: m(420)...m(420), futureRest: m(40)))
        #expect(try Worktime.preview(bounds: bounds, now: m(50), candidate: m(75), remainingRest: m(40), state: .onBreak(returnAt: m(90))) == .infeasible)
        #expect(try Worktime.preview(bounds: bounds, now: m(50), candidate: m(480), remainingRest: m(40), state: .onBreak(returnAt: nil)) == .unknown)
        #expect(try Worktime.preview(bounds: bounds, now: m(50), candidate: m(50), remainingRest: m(40), state: .onBreak(returnAt: nil)) == .feasible(worked: m(30)...m(30), futureRest: 0))
        #expect(try Worktime.preview(bounds: bounds, now: m(50), candidate: m(480), remainingRest: m(40), state: .ended) == .ended)
    }
}
