import Testing
@testable import WorktimeDomain

struct DailyForecastTests {
    @Test func `distinct targets include future rest only in departure`() throws {
        let result = try DailyForecast.calculate(
            worked: 60 ... 60, target: 25200, remainingRest: 3600, now: 60, state: .working
        )
        #expect(result.remaining == 25140 ... 25140)
        #expect(result.surplus == 0 ... 0)
        #expect(result.goal == .projected(earliestGoalAt: 25200, estimatedDepartureAt: 28800))
    }

    @Test func `uncertainty prevents exact future prediction`() throws {
        let result = try DailyForecast.calculate(
            worked: 100 ... 150, target: 120, remainingRest: 60, now: 200, state: .working
        )
        #expect(result.remaining == 0 ... 20)
        #expect(result.surplus == 0 ... 30)
        #expect(result.goal == .uncertain)
    }

    @Test func `confirmed attainment retires target countdown despite remaining rest`() throws {
        let result = try DailyForecast.calculate(
            worked: 120 ... 150, target: 120, remainingRest: 60, now: 200, state: .onBreak(returnAt: nil)
        )
        #expect(result.remaining == 0 ... 0)
        #expect(result.surplus == 0 ... 30)
        #expect(result.goal == .reached)
    }

    @Test func `break and ended states suppress future predictions`() throws {
        let active = try DailyForecast.calculate(
            worked: 60 ... 60, target: 120, remainingRest: 30, now: 100, state: .onBreak(returnAt: nil)
        )
        #expect(active.goal == .onBreak)
        let ended = try DailyForecast.calculate(
            worked: 60 ... 60, target: 120, remainingRest: 30, now: 200, state: .ended
        )
        #expect(ended.goal == .ended)
        #expect(ended.remaining == active.remaining)
    }

    @Test func `overflow and invalid durations fail closed`() throws {
        #expect(throws: WorktimeError.overflow) {
            try DailyForecast.calculate(
                worked: 0 ... 0, target: 1, remainingRest: 1, now: Int64.max - 1, state: .working
            )
        }
        #expect(throws: WorktimeError.invalidDuration) {
            try DailyForecast.calculate(worked: 0 ... 0, target: 0, remainingRest: 0, now: 0, state: .working)
        }
    }
}
