import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain

struct DesiredDepartureAssessmentTests {
    private func catalog(rest: Int64 = 3600) throws -> WorkdayCatalog {
        var catalog = WorkdayCatalog()
        let profile = try WorkdayProfile(expectedRest: rest)
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: 0, now: 0, expectedRevision: 0)
        return catalog
    }

    @Test func `infeasible intention needs warning and cannot notify`() throws {
        let catalog = try catalog()
        let glance = try WorktimeGlance(catalog: catalog, now: 24000)
        let result = try glance.assessDesiredDeparture(at: 27000)
        #expect(result.status == .infeasible)
        #expect(result.requiresWarning)
        #expect(!result.canSave(warningAcknowledged: false))
        #expect(result.canSave(warningAcknowledged: true))
        #expect(result.notificationTarget == nil)
        #expect(glance.forecast.goal == .projected(earliestGoalAt: 25200, estimatedDepartureAt: 28800))
        #expect(catalog.revision == 1)
    }

    @Test func `feasible intention may have target shortfall and distinct notification time`() throws {
        let glance = try WorktimeGlance(catalog: catalog(), now: 1800)
        let result = try glance.assessDesiredDeparture(at: 27000)
        #expect(result.status == .feasible)
        #expect(result.canSave(warningAcknowledged: false))
        #expect(result.scenario.remaining == 1800 ... 1800)
        #expect(result.notificationTarget == 27000)
    }

    @Test func `uncertain history and current break suppress precise intention notifications`() throws {
        var catalog = try catalog()
        let id = try #require(catalog.activeID)
        try catalog.recordObservation(dayID: id, gap: .init(start: 20, end: 80), now: 100,
                                      expected: catalog.reviewVersion)
        let working = try WorktimeGlance(catalog: catalog, now: 100)
        let uncertain = try working.assessDesiredDeparture(at: 28800)
        #expect(uncertain.status == .uncertain)
        #expect(uncertain.notificationTarget == nil)
        #expect(!uncertain.canSave(warningAcknowledged: false))
        #expect(uncertain.canSave(warningAcknowledged: true))
        try catalog.apply(.startBreak, at: 110, now: 110, expectedRevision: catalog.revision)
        let resting = try WorktimeGlance(catalog: catalog, now: 120)
        let unknown = try resting.assessDesiredDeparture(at: 28800)
        #expect(unknown.status == .uncertain)
        #expect(unknown.scenario.result == .unknown)
        #expect(unknown.notificationTarget == nil)
    }

    @Test func `elapsed and ended intentions cannot save or notify even with warning acknowledgement`() throws {
        var catalog = try catalog()
        let working = try WorktimeGlance(catalog: catalog, now: 100)
        for candidate in [Int64(99), 100] {
            let result = try working.assessDesiredDeparture(at: candidate)
            #expect(result.status == .expired)
            #expect(!result.canSave(warningAcknowledged: true))
            #expect(result.notificationTarget == nil)
        }
        try catalog.apply(.clockOut(confirmBreak: false), at: 110, now: 110, expectedRevision: catalog.revision)
        let ended = try WorktimeGlance(catalog: catalog, now: 120)
        let result = try ended.assessDesiredDeparture(at: 28800)
        #expect(result.status == .ended)
        #expect(!result.canSave(warningAcknowledged: true))
        #expect(result.notificationTarget == nil)
    }

    @Test func `recorded target attainment does not invalidate an explicit future intention`() throws {
        let glance = try WorktimeGlance(catalog: catalog(rest: 0), now: 25200)
        let result = try glance.assessDesiredDeparture(at: 26000)
        #expect(glance.forecast.goal == .reached)
        #expect(result.status == .feasible)
        #expect(result.notificationTarget == 26000)
    }
}
