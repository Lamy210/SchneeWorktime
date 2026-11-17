import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct DesiredDepartureStoreTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worktime.sqlite")
        try body(url, CatalogRepository(url: url, createIfMissing: true))
    }

    @Test func `explicit intention survives replay without changing attendance and clears explicitly`() throws {
        try withRepository { url, repo in
            let initial = try repo.load(now: 100)
            let id = UUID()
            let started = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let saved = try repo.setDesiredDeparture(
                dayID: id, candidate: 27000, warningAcknowledged: false, now: 101, expected: started.version
            )
            let reopened = try CatalogRepository(url: url).load(now: 102)
            #expect(reopened.catalog == saved.catalog)
            #expect(reopened.catalog.desiredDepartures[id] == 27000)
            #expect(reopened.catalog.days.last?.intervals == started.catalog.days.last?.intervals)
            #expect(reopened.catalog.activeID == id)
            #expect(reopened.catalog.days.last?.revision != started.catalog.days.last?.revision)
            let cleared = try repo.setDesiredDeparture(
                dayID: id, candidate: nil, warningAcknowledged: false, now: 103, expected: reopened.version
            )
            #expect(cleared.catalog.desiredDepartures[id] == nil)
        }
    }

    @Test func `infeasible intention requires warning and stale or elapsed inputs cannot mutate storage`() throws {
        try withRepository { url, repo in
            let initial = try repo.load(now: 100)
            let id = UUID()
            let started = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            #expect(throws: WorkdayError.confirmationRequired) {
                try repo.setDesiredDeparture(
                    dayID: id, candidate: 200, warningAcknowledged: false, now: 101, expected: started.version
                )
            }
            #expect(throws: WorkdayError.invalidEventTime) {
                try repo.setDesiredDeparture(
                    dayID: id, candidate: 101, warningAcknowledged: true, now: 101, expected: started.version
                )
            }
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.setDesiredDeparture(
                    dayID: id, candidate: 27000, warningAcknowledged: true, now: 101, expected: initial.version
                )
            }
            #expect(try store.load() == before)
            let saved = try repo.setDesiredDeparture(
                dayID: id, candidate: 200, warningAcknowledged: true, now: 101, expected: started.version
            )
            let expired = try repo.load(now: 201)
            #expect(expired.catalog.desiredDepartures[id] == 200)
            #expect(expired.version == saved.version)
            #expect(expired.catalog.activeID == id)
        }
    }

    @Test func `ended intention remains historical and does not leak to next day`() throws {
        try withRepository { _, repo in
            let initial = try repo.load(now: 100)
            let id = UUID()
            let started = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let saved = try repo.setDesiredDeparture(
                dayID: id, candidate: 27000, warningAcknowledged: false, now: 101, expected: started.version
            )
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 110, now: 110, expected: saved.version)
            #expect(ended.catalog.desiredDepartures[id] == 27000)
            #expect(throws: WorkdayError.noActiveDay) {
                try repo.setDesiredDeparture(
                    dayID: id, candidate: nil, warningAcknowledged: false, now: 111, expected: ended.version
                )
            }
            let nextID = UUID()
            let next = try repo.apply(
                .clockIn(id: nextID, profile: WorkdayProfile()), at: 120, now: 120, expected: ended.version
            )
            #expect(next.catalog.desiredDepartures[nextID] == nil)
            #expect(next.catalog.desiredDepartures[id] == 27000)
        }
    }
}
