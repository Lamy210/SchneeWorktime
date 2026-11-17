import Testing
import WorktimeApplication
import WorktimeDomain

struct DepartureCountdownTests {
    @Test func `departure and earliest goal are separate and update with observed time`() {
        let goal = GoalForecast.projected(earliestGoalAt: 3700, estimatedDepartureAt: 7300)
        let initial = DepartureCountdown(goal: goal, observedAt: 100)
        #expect(initial == .projected(earliestSeconds: 3600, departureSeconds: 7200))
        #expect(initial.menuTitle == "退勤まで 2:00:00")
        let next = DepartureCountdown(goal: goal, observedAt: 101)
        #expect(next == .projected(earliestSeconds: 3599, departureSeconds: 7199))
        #expect(next.menuTitle == "退勤まで 1:59:59")
    }

    @Test func `non projected states cannot display a precise countdown`() {
        let cases: [(GoalForecast, DepartureCountdown, String)] = [
            (.reached, .reached, "目標達成"),
            (.uncertain, .uncertain, "要確認"),
            (.onBreak, .onBreak, "休憩中"),
            (.ended, .ended, "退勤済み")
        ]
        for (goal, expected, label) in cases {
            let countdown = DepartureCountdown(goal: goal, observedAt: 100)
            #expect(countdown == expected)
            #expect(countdown.menuTitle == label)
        }
    }

    @Test func `expired reversed or overflowing projections are unavailable`() {
        let cases: [(GoalForecast, Int64)] = [
            (.projected(earliestGoalAt: 100, estimatedDepartureAt: 120), 100),
            (.projected(earliestGoalAt: 120, estimatedDepartureAt: 110), 100),
            (.projected(earliestGoalAt: Int64.max, estimatedDepartureAt: Int64.max), -1)
        ]
        for (goal, now) in cases {
            #expect(DepartureCountdown(goal: goal, observedAt: now) == .unavailable)
        }
    }

    @Test func `duration preserves seconds and supports more than 24 hours`() {
        #expect(DepartureCountdown.duration(0) == "0:00:00")
        #expect(DepartureCountdown.duration(1) == "0:00:01")
        #expect(DepartureCountdown.duration(3661) == "1:01:01")
        #expect(DepartureCountdown.duration(90061) == "25:01:01")
        #expect(DepartureCountdown.duration(-1) == "0:00:00")
    }
}
