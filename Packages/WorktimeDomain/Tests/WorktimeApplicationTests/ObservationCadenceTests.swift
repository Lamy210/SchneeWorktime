import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain

struct ObservationCadenceTests {
    @Test func `active work and break preserve one second observation`() {
        let states: [WorkdayState] = [.working, .onBreak]
        for state in states {
            let cadence = ObservationCadence(dayState: state)
            #expect(cadence == .active)
            #expect(cadence.interval == 1)
            #expect(cadence.tolerance == 0)
        }
    }

    @Test func `idle cadence stays well inside the unobserved threshold`() {
        let states: [WorkdayState?] = [nil, .ended]
        for state in states {
            let cadence = ObservationCadence(dayState: state)
            #expect(cadence == .idle)
            #expect(cadence.interval == 5)
            #expect(cadence.interval + cadence.tolerance < 15)
        }
    }

    @Test func `idle polling does not relax clock anomaly and gap detection`() throws {
        let start = try ClockSample(wall: 100, uptime: 100)
        var clock = ClockObservation(initial: start)
        let ordinary = try ClockSample(wall: 105, uptime: 105)
        #expect(try clock.advance(to: ordinary) == nil)
        let gap = try ClockSample(wall: 121, uptime: 121)
        #expect(try clock.advance(to: gap) == ObservationGap(start: 105, end: 121))
        let invalid = try ClockSample(wall: 140, uptime: 122)
        #expect(throws: ApplicationClockError.unreliableClock) {
            try clock.advance(to: invalid)
        }
    }
}
