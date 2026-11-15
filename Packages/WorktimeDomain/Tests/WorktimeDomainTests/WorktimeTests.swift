import Testing
@testable import WorktimeDomain

struct WorktimeTests {
    private func seconds(_ minute: Int64) -> Int64 {
        minute * 60
    }

    @Test func `attainment and crossing`() throws {
        let spans = [
            WorkSpan(start: 0, end: seconds(300), verified: true),
            WorkSpan(start: seconds(300), end: seconds(360), verified: false),
            WorkSpan(start: seconds(360), end: seconds(480), verified: true)
        ]
        let result = try Worktime.bounds(spans: spans, now: seconds(480), target: seconds(420))
        #expect(result.lower == seconds(420))
        #expect(result.upper == seconds(480))
        #expect(result.attainment == .reached)
        #expect(result.crossing == .range(seconds(420) ... seconds(480)))
    }

    @Test func `possible not confirmed`() throws {
        let spans = [
            WorkSpan(start: 0, end: seconds(360), verified: true),
            WorkSpan(start: seconds(360), end: seconds(420), verified: false)
        ]
        let result = try Worktime.bounds(spans: spans, now: seconds(420), target: seconds(420))
        #expect(result.attainment == .possible)
        #expect(result.crossing == .unavailable)
    }

    @Test func `exact before later uncertainty`() throws {
        let spans = [
            WorkSpan(start: 0, end: seconds(420), verified: true),
            WorkSpan(start: seconds(420), end: seconds(480), verified: false)
        ]
        let result = try Worktime.bounds(spans: spans, now: seconds(480), target: seconds(420))
        #expect(result.crossing == .exact(seconds(420)))
    }

    @Test func `reject overlap and future`() throws {
        let overlapping = [
            WorkSpan(start: 0, end: 60, verified: true),
            WorkSpan(start: 30, end: 90, verified: false)
        ]
        let future = [WorkSpan(start: 0, end: 61, verified: true)]
        #expect(throws: WorktimeError.overlappingIntervals) {
            try Worktime.bounds(spans: overlapping, now: 90, target: 60)
        }
        #expect(throws: WorktimeError.invalidInterval) {
            try Worktime.bounds(spans: future, now: 60, target: 60)
        }
    }

    @Test func `impossible rest and leave now`() throws {
        let now = seconds(400)
        let bounds = try Worktime.bounds(spans: [.init(start: 0, end: now, verified: true)],
                                         now: now, target: seconds(420))
        let impossible = try Worktime.preview(bounds: bounds, now: now, candidate: seconds(450),
                                              remainingRest: seconds(60), state: .working)
        #expect(impossible == .infeasible)
        let feasible = try Worktime.preview(bounds: bounds, now: now, candidate: seconds(450),
                                            remainingRest: seconds(30), state: .working)
        #expect(feasible == .feasible(worked: seconds(420) ... seconds(420), futureRest: seconds(30)))
        let leaveNow = try Worktime.preview(bounds: bounds, now: now, candidate: now,
                                            remainingRest: seconds(60), state: .working)
        #expect(leaveNow == .feasible(worked: now ... now, futureRest: 0))
        let past = try Worktime.preview(bounds: bounds, now: now, candidate: seconds(399),
                                        remainingRest: 0, state: .working)
        #expect(past == .invalidCandidate)
    }

    @Test func `active break consumes budget once`() throws {
        let now = seconds(50)
        let rest = seconds(40)
        let candidate = seconds(480)
        let bounds = try Worktime.bounds(spans: [.init(start: 0, end: seconds(30), verified: true)],
                                         now: now, target: seconds(420))
        let state = PreviewState.onBreak(returnAt: seconds(90))
        let feasible = try Worktime.preview(bounds: bounds, now: now, candidate: candidate,
                                            remainingRest: rest, state: state)
        #expect(feasible == .feasible(worked: seconds(420) ... seconds(420), futureRest: rest))
        let impossible = try Worktime.preview(bounds: bounds, now: now, candidate: seconds(75),
                                              remainingRest: rest, state: state)
        #expect(impossible == .infeasible)
        let unknown = try Worktime.preview(bounds: bounds, now: now, candidate: candidate,
                                           remainingRest: rest, state: .onBreak(returnAt: nil))
        #expect(unknown == .unknown)
        let leaveNow = try Worktime.preview(bounds: bounds, now: now, candidate: now,
                                            remainingRest: rest, state: .onBreak(returnAt: nil))
        #expect(leaveNow == .feasible(worked: seconds(30) ... seconds(30), futureRest: 0))
        let ended = try Worktime.preview(bounds: bounds, now: now, candidate: candidate,
                                         remainingRest: rest, state: .ended)
        #expect(ended == .ended)
    }
}
