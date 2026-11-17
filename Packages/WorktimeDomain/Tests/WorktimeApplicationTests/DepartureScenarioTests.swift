import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain

struct DepartureScenarioTests {
    private func day(target: Int64 = 25200, rest: Int64 = 3600) throws -> WorkdayCatalog {
        var catalog = WorkdayCatalog()
        let profile = try WorkdayProfile(target: target, expectedRest: rest)
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: 0, now: 0, expectedRevision: 0)
        return catalog
    }

    @Test func `next day settings reject invalid inputs and keep prior profile immutable`() throws {
        var catalog = try day()
        let settings = try NextDaySettings(targetMinutes: 480, restMinutes: 45)
        #expect(catalog.days.last?.profile.target == 25200)
        try catalog.apply(.clockOut(confirmBreak: false), at: 60, now: 60, expectedRevision: catalog.revision)
        try catalog.apply(.clockIn(id: UUID(), profile: settings.profile), at: 61, now: 61,
                          expectedRevision: catalog.revision)
        #expect(catalog.days.first?.profile.target == 25200)
        #expect(catalog.days.last?.profile.target == 28800)
        #expect(catalog.days.last?.profile.expectedRest == 2700)
        #expect(throws: WorkdayError.invalidProfile) {
            try NextDaySettings(targetMinutes: Int.max, restMinutes: 60)
        }
        #expect(throws: WorkdayError.invalidProfile) {
            try NextDaySettings(targetMinutes: 420, restMinutes: -1)
        }
    }

    @Test func `working preview separates future rest from actual record`() throws {
        let catalog = try day()
        let glance = try WorktimeGlance(catalog: catalog, now: 1800)
        let result = try glance.departureScenario(candidate: 21600)
        #expect(result.result == .feasible(worked: 18000 ... 18000, futureRest: 3600))
        #expect(result.remaining == 7200 ... 7200)
        #expect(result.surplus == 0 ... 0)
        #expect(result.observedAt == 1800)
        #expect(catalog.revision == 1)
        #expect(glance.snapshot.bounds.lower == 1800)
    }

    @Test func `infeasible past and leave now are distinguished`() throws {
        let glance = try WorktimeGlance(catalog: day(), now: 1800)
        #expect(try glance.departureScenario(candidate: 2000).result == .infeasible)
        #expect(try glance.departureScenario(candidate: 1799).result == .invalidCandidate)
        let now = try glance.departureScenario(candidate: 1800)
        #expect(now.result == .feasible(worked: 1800 ... 1800, futureRest: 0))
    }

    @Test func `break requires explicit return assumption for future preview`() throws {
        var catalog = try day()
        try catalog.apply(.startBreak, at: 1800, now: 1800, expectedRevision: catalog.revision)
        let glance = try WorktimeGlance(catalog: catalog, now: 3000)
        #expect(try glance.departureScenario(candidate: 28800).result == .unknown)
        let result = try glance.departureScenario(candidate: 28800, returnAt: 5400)
        #expect(result.result == .feasible(worked: 25200 ... 25200, futureRest: 2400))
        #expect(result.remaining == 0 ... 0)
        #expect(try glance.departureScenario(candidate: 3600, returnAt: 5400).result == .infeasible)
    }

    @Test func `uncertainty produces bounded shortfall and surplus and ended has no future projection`() throws {
        var catalog = try day(target: 100, rest: 0)
        let id = try #require(catalog.activeID)
        try catalog.recordObservation(dayID: id, gap: .init(start: 20, end: 80), now: 90,
                                      expected: catalog.reviewVersion)
        let glance = try WorktimeGlance(catalog: catalog, now: 90)
        let result = try glance.departureScenario(candidate: 130)
        #expect(result.result == .feasible(worked: 70 ... 130, futureRest: 0))
        #expect(result.remaining == 0 ... 30)
        #expect(result.surplus == 0 ... 30)
        try catalog.apply(.clockOut(confirmBreak: false), at: 90, now: 90, expectedRevision: catalog.revision)
        let ended = try WorktimeGlance(catalog: catalog, now: 200)
        #expect(try ended.departureScenario(candidate: 300).result == .ended)
    }
}
