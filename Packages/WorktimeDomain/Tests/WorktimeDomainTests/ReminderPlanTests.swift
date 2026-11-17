import Testing
@testable import WorktimeDomain

struct ReminderPlanTests {
    @Test func `default prepares for departure not earliest goal`() {
        let result = ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: 25200, estimatedDepartureAt: 28800),
            now: 0, clockTrusted: true
        )
        #expect(result == [PlannedReminder(kind: .departurePreparation(.fifteen), trigger: 27900)])
    }

    @Test func `elapsed and exact now triggers are omitted`() {
        let result = ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: 3600, estimatedDepartureAt: 3600),
            now: 2700, clockTrusted: true, departureLeads: [.five, .fifteen, .thirty]
        )
        #expect(result == [PlannedReminder(kind: .departurePreparation(.five), trigger: 3300)])
    }

    @Test func `categories remain distinct even with matching triggers`() {
        let result = ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: 3600, estimatedDepartureAt: 3600),
            now: 0, clockTrusted: true, earliestLeads: [.fifteen], referenceAt: 2700
        )
        #expect(Set(result.map(\.kind)).count == 3)
        #expect(result.allSatisfy { $0.trigger == 2700 })
        #expect(result == ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: 3600, estimatedDepartureAt: 3600),
            now: 0, clockTrusted: true, earliestLeads: [.fifteen], referenceAt: 2700
        ))
    }

    @Test func `uncertain break and reached keep only independent reference`() {
        for forecast: GoalForecast in [.uncertain, .onBreak, .reached] {
            let result = ReminderPlan.desired(forecast: forecast, now: 0, clockTrusted: true, referenceAt: 100)
            #expect(result == [PlannedReminder(kind: .referenceEnd, trigger: 100)])
        }
    }

    @Test func `ended or untrusted clock suppress all requests`() {
        #expect(ReminderPlan.desired(forecast: .ended, now: 0, clockTrusted: true, referenceAt: 100).isEmpty)
        #expect(ReminderPlan.desired(forecast: .uncertain, now: 0, clockTrusted: false, referenceAt: 100).isEmpty)
    }

    @Test func `malformed forecasts and underflow cannot generate requests`() {
        #expect(ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: 100, estimatedDepartureAt: 99), now: 0, clockTrusted: true
        ).isEmpty)
        #expect(ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: Int64.min + 1, estimatedDepartureAt: Int64.min + 2),
            now: Int64.min, clockTrusted: true
        ).isEmpty)
    }
}
