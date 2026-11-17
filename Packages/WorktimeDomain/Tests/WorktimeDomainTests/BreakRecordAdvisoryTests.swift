import Foundation
import Testing
import WorktimeDomain

struct BreakRecordAdvisoryTests {
    private func snapshot(work: Int64, rest: Int64, uncertain: Int64 = 0) throws -> TimelineSnapshot {
        let end = work + rest
        let intervals: [RecordedInterval] = [
            .init(start: 0, end: work, kind: .work),
            .init(start: work, end: end, kind: .rest)
        ].filter { $0.start != $0.end }
        let gaps: [ObservationGap] = uncertain == 0 ? [] : [.init(start: 0, end: uncertain)]
        return try Timeline.snapshot(intervals: intervals, uncertainty: gaps, now: end,
                                     target: 25200, expectedRest: 3600)
    }

    @Test func `short recorded rest does not revoke recorded goal attainment`() throws {
        let profile = try WorkdayProfile()
        let recorded = try snapshot(work: 25200, rest: 1800)
        #expect(BreakRecordAdvisory.assess(snapshot: recorded, profile: profile) == .review)
        #expect(recorded.bounds.attainment == .reached)
        #expect(recorded.recordedRest == 1800)
    }

    @Test func `eight hour boundary and missing rest are distinguished`() throws {
        let profile = try WorkdayProfile(target: 36000, expectedRest: 0)
        let exact = try snapshot(work: 28800, rest: 2700)
        let beyond = try snapshot(work: 28801, rest: 2700)
        let sufficient = try snapshot(work: 28801, rest: 3600)
        #expect(BreakRecordAdvisory.assess(snapshot: exact, profile: profile) == .none)
        #expect(BreakRecordAdvisory.assess(snapshot: beyond, profile: profile) == .review)
        #expect(BreakRecordAdvisory.assess(snapshot: sufficient, profile: profile) == .none)
    }

    @Test func `uncertain work has a separate possible review hint`() throws {
        let profile = try WorkdayProfile()
        let recorded = try snapshot(work: 25200, rest: 0, uncertain: 7200)
        #expect(BreakRecordAdvisory.assess(snapshot: recorded, profile: profile) == .possibleReview)
    }

    @Test func `completed standard break and shorter shift need no hint`() throws {
        let profile = try WorkdayProfile()
        let complete = try snapshot(work: 25200, rest: 3600)
        let short = try snapshot(work: 21600, rest: 0)
        #expect(BreakRecordAdvisory.assess(snapshot: complete, profile: profile) == .none)
        #expect(BreakRecordAdvisory.assess(snapshot: short, profile: profile) == .none)
    }
}
