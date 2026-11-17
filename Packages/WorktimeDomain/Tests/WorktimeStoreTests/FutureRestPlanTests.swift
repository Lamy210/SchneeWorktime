import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct FutureRestPlanTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worktime.sqlite")
        try body(url, CatalogRepository(url: url, createIfMissing: true))
    }

    @Test func `plan consumes only rest after anchor and survives replay`() throws {
        try withRepository { url, repo in
            let initial = try repo.load(now: 100)
            let day = UUID()
            let profile = try WorkdayProfile()
            let started = try repo.apply(.clockIn(id: day, profile: profile), at: 100, now: 100,
                                         expected: initial.version)
            let rest = try repo.apply(.startBreak, at: 200, now: 200, expected: started.version)
            let work = try repo.apply(.endBreak, at: 800, now: 800, expected: rest.version)
            let planned = try repo.setFutureRest(dayID: day, remainingSeconds: 1800,
                                                now: 1000, expected: work.version)
            let before = try planned.catalog.snapshot(dayID: day, now: 1000)
            #expect(before.recordedRest == 600)
            #expect(before.remainingRest == 1800)
            #expect(planned.catalog.days.last?.intervals == work.catalog.days.last?.intervals)
            let secondRest = try repo.apply(.startBreak, at: 1100, now: 1100, expected: planned.version)
            let resumed = try repo.apply(.endBreak, at: 2300, now: 2300, expected: secondRest.version)
            let restored = try CatalogRepository(url: url).load(now: 2300)
            #expect(restored.catalog == resumed.catalog)
            let after = try restored.catalog.snapshot(dayID: day, now: 2300)
            #expect(after.recordedRest == 1800)
            #expect(after.remainingRest == 600)
            let cleared = try repo.setFutureRest(dayID: day, remainingSeconds: nil,
                                                now: 2300, expected: restored.version)
            let standard = try cleared.catalog.snapshot(dayID: day, now: 2300)
            #expect(standard.recordedRest == 1800)
            #expect(standard.remainingRest == 1800)
            #expect(cleared.catalog.days.last?.futureRestPlan == nil)
        }
    }

    @Test func `correction before anchor does not consume remaining rest`() throws {
        try withRepository { _, repo in
            let initial = try repo.load(now: 100)
            let day = UUID()
            let started = try repo.apply(.clockIn(id: day, profile: WorkdayProfile()), at: 100, now: 100,
                                         expected: initial.version)
            let gap = try repo.recordObservation(dayID: day, gap: .init(start: 200, end: 800),
                                                 now: 1000, expected: started.version)
            let planned = try repo.setFutureRest(dayID: day, remainingSeconds: 1800,
                                                now: 1000, expected: gap.version)
            let proposal = try planned.previewReview(dayID: day, selection: .init(start: 200, end: 800),
                                                    classification: .rest, now: 1001)
            let corrected = try repo.commitReview(proposal, now: 1001)
            let snapshot = try corrected.catalog.snapshot(dayID: day, now: 1001)
            #expect(snapshot.recordedRest == 600)
            #expect(snapshot.remainingRest == 1800)
            #expect(corrected.catalog.days.last?.futureRestPlan == planned.catalog.days.last?.futureRestPlan)
        }
    }

    @Test func `invalid amount stale version and ended day reject without mutation`() throws {
        try withRepository { url, repo in
            let initial = try repo.load(now: 100)
            let day = UUID()
            let started = try repo.apply(.clockIn(id: day, profile: WorkdayProfile()), at: 100, now: 100,
                                         expected: initial.version)
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            #expect(throws: WorkdayError.invalidProfile) {
                try repo.setFutureRest(dayID: day, remainingSeconds: -1, now: 101, expected: started.version)
            }
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.setFutureRest(dayID: day, remainingSeconds: 0, now: 101, expected: initial.version)
            }
            #expect(try store.load() == before)
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 110, now: 110,
                                       expected: started.version)
            let endedSnapshot = try store.load()
            #expect(throws: WorkdayError.noActiveDay) {
                try repo.setFutureRest(dayID: day, remainingSeconds: 0, now: 111, expected: ended.version)
            }
            #expect(try store.load() == endedSnapshot)
        }
    }
}
