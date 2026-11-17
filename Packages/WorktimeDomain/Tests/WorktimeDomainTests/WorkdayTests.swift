import Foundation
import Testing
@testable import WorktimeDomain

struct WorkdayTests {
    private func started(at instant: Int64 = 100) throws -> WorkdayCatalog {
        var catalog = WorkdayCatalog()
        let profile = try WorkdayProfile()
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: instant, now: instant, expectedRevision: 0)
        return catalog
    }

    @Test func `work break and clock out freeze recorded time`() throws {
        var catalog = try started()
        let id = catalog.activeID
        try catalog.apply(.startBreak, at: 200, now: 200, expectedRevision: 1)
        try catalog.apply(.endBreak, at: 260, now: 260, expectedRevision: 2)
        try catalog.apply(.clockOut(confirmBreak: false), at: 360, now: 360, expectedRevision: 3)
        let day = try #require(catalog.days.first)
        #expect(day.id == id)
        #expect(catalog.activeID == nil)
        #expect(day.state == .ended)
        #expect(day.revision == 4)
        let result = try day.snapshot(now: 1000)
        #expect(result.bounds.lower == 200)
        #expect(result.recordedRest == 60)
    }

    @Test func `clock out during break requires confirmation`() throws {
        var catalog = try started()
        try catalog.apply(.startBreak, at: 200, now: 200, expectedRevision: 1)
        let previous = catalog
        #expect(throws: WorkdayError.confirmationRequired) {
            try catalog.apply(.clockOut(confirmBreak: false), at: 250, now: 250, expectedRevision: 2)
        }
        #expect(catalog == previous)
        try catalog.apply(.clockOut(confirmBreak: true), at: 250, now: 250, expectedRevision: 2)
        let day = try #require(catalog.days.last)
        #expect(day.intervals.count == 2)
        let result = try day.snapshot(now: 500)
        #expect(result.bounds.lower == 100)
        #expect(result.recordedRest == 50)
    }

    @Test func `stale and duplicate actions leave state unchanged`() throws {
        var catalog = try started()
        let original = catalog
        let profile = try WorkdayProfile()
        #expect(throws: WorkdayError.staleRevision) {
            try catalog.apply(.startBreak, at: 150, now: 150, expectedRevision: 0)
        }
        #expect(throws: WorkdayError.activeDayExists) {
            try catalog.apply(.clockIn(id: UUID(), profile: profile), at: 150, now: 150, expectedRevision: 1)
        }
        #expect(throws: WorkdayError.invalidTransition) {
            try catalog.apply(.endBreak, at: 150, now: 150, expectedRevision: 1)
        }
        #expect(catalog == original)
    }

    @Test func `same second and future transitions are rejected without mutation`() throws {
        var catalog = try started()
        let original = catalog
        #expect(throws: WorkdayError.zeroLengthInterval) {
            try catalog.apply(.clockOut(confirmBreak: false), at: 100, now: 100, expectedRevision: 1)
        }
        #expect(throws: WorkdayError.invalidEventTime) {
            try catalog.apply(.startBreak, at: 99, now: 120, expectedRevision: 1)
        }
        #expect(throws: WorkdayError.invalidEventTime) {
            try catalog.apply(.startBreak, at: 121, now: 120, expectedRevision: 1)
        }
        #expect(catalog == original)
    }

    @Test func `cross midnight resume keeps identity and excludes gap`() throws {
        var catalog = try started(at: 75600)
        let id = try #require(catalog.activeID)
        try catalog.apply(.clockOut(confirmBreak: false), at: 88200, now: 88200, expectedRevision: 1)
        try catalog.apply(.resume(id: id), at: 90000, now: 90000, expectedRevision: 2)
        let day = try #require(catalog.days.last)
        #expect(catalog.days.count == 1)
        #expect(day.id == id)
        let result = try day.snapshot(now: 91800)
        #expect(result.bounds.lower == 14400)
        #expect(result.recordedRest == 0)
    }

    @Test func `cannot resume old day or reuse its identity`() throws {
        var catalog = try started()
        let first = try #require(catalog.activeID)
        try catalog.apply(.clockOut(confirmBreak: false), at: 200, now: 200, expectedRevision: 1)
        let profile = try WorkdayProfile()
        #expect(throws: WorkdayError.duplicateID) {
            try catalog.apply(.clockIn(id: first, profile: profile), at: 300, now: 300, expectedRevision: 2)
        }
        #expect(throws: WorkdayError.invalidEventTime) {
            try catalog.apply(.clockIn(id: UUID(), profile: profile), at: 199, now: 300, expectedRevision: 2)
        }
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: 300, now: 300, expectedRevision: 2)
        try catalog.apply(.clockOut(confirmBreak: false), at: 400, now: 400, expectedRevision: 3)
        let original = catalog
        #expect(throws: WorkdayError.notLatestEndedDay) {
            try catalog.apply(.resume(id: first), at: 500, now: 500, expectedRevision: 4)
        }
        #expect(catalog == original)
    }

    @Test func `profile targets are fixed and time before start is refused`() throws {
        let profile = try WorkdayProfile(target: 300, expectedRest: 100)
        var catalog = WorkdayCatalog()
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: 100, now: 120, expectedRevision: 0)
        let day = try #require(catalog.days.last)
        #expect(day.profile == profile)
        let result = try day.snapshot(now: 120)
        #expect(result.bounds.lower == 20)
        #expect(result.remainingRest == 100)
        #expect(throws: WorkdayError.invalidEventTime) {
            try day.snapshot(now: 99)
        }
        #expect(throws: WorkdayError.invalidProfile) {
            try WorkdayProfile(target: 0)
        }
    }

    @Test func `touching workday boundaries are valid`() throws {
        var catalog = try started()
        let first = try #require(catalog.activeID)
        try catalog.apply(.clockOut(confirmBreak: false), at: 200, now: 200, expectedRevision: 1)
        try catalog.apply(.resume(id: first), at: 200, now: 200, expectedRevision: 2)
        try catalog.apply(.clockOut(confirmBreak: false), at: 300, now: 300, expectedRevision: 3)
        let next = UUID()
        let profile = try WorkdayProfile()
        try catalog.apply(.clockIn(id: next, profile: profile), at: 300, now: 300, expectedRevision: 4)
        #expect(catalog.activeID == next)
        #expect(catalog.days.count == 2)
        let previous = try #require(catalog.days.first)
        let result = try previous.snapshot(now: 300)
        #expect(result.bounds.lower == 200)
        let active = try #require(catalog.days.last)
        let initial = try active.snapshot(now: 300)
        #expect(initial.bounds.lower == 0)
    }

    @Test func `closed snapshot clips valid observations at actual end`() throws {
        var catalog = try started()
        try catalog.apply(.clockOut(confirmBreak: false), at: 200, now: 300, expectedRevision: 1)
        let day = try #require(catalog.days.last)
        let gaps = [ObservationGap(start: 150, end: 250), ObservationGap(start: 260, end: 280)]
        let result = try day.snapshot(now: 300, uncertainty: gaps)
        #expect(result.bounds.lower == 50)
        #expect(result.bounds.upper == 100)
        #expect(throws: WorktimeError.invalidInterval) {
            try day.snapshot(now: 300, uncertainty: [.init(start: 260, end: 301)])
        }
    }
}
