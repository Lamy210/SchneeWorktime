import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CapturedReferenceStoreTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worktime.sqlite")
        try body(url, CatalogRepository(url: url, createIfMissing: true))
    }

    private func instant(_ text: String) throws -> Int64 {
        let date = try #require(ISO8601DateFormatter().date(from: text))
        return Int64(date.timeIntervalSince1970)
    }

    @Test func `captured overnight reference survives replay and keeps original profile across resume`() throws {
        try withRepository { url, repo in
            let start = try instant("2026-11-17T12:00:00Z")
            let end = try instant("2026-11-17T21:10:00Z")
            let reference = try CapturedReference(
                startedAt: start, timeZoneID: "Asia/Tokyo", wallTime: ReferenceWallTime(hour: 6, dayOffset: 1)
            )
            let initial = try repo.load(now: start)
            let id = UUID()
            let profile = try WorkdayProfile(reference: reference)
            let started = try repo.apply(
                .clockIn(id: id, profile: profile), at: start, now: start, expected: initial.version
            )
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: end, now: end, expected: started.version)
            let reopened = try CatalogRepository(url: url).load(now: end + 100)
            #expect(reopened.catalog == ended.catalog)
            let saved = try #require(reopened.catalog.days.last?.profile.reference)
            #expect(saved.logicalDate == "2026-11-17")
            #expect(saved.timeZoneID == "Asia/Tokyo")
            #expect(saved.referenceAt == end - 600)
            #expect(try saved.difference(at: end) == 600)
            let resumed = try repo.apply(.resume(id: id), at: end + 100, now: end + 100, expected: reopened.version)
            #expect(resumed.catalog.days.last?.profile.reference == reference)
        }
    }

    @Test func `legacy clock in remains readable without invented timezone and mismatched capture rejects`() throws {
        try withRepository { url, repo in
            let initial = try repo.load(now: 100)
            let legacy = try repo.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            #expect(legacy.catalog.days.last?.profile.reference == nil)
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 110, now: 110, expected: legacy.version)
            let reference = try CapturedReference(startedAt: 111, timeZoneID: "Asia/Tokyo", wallTime: nil)
            let profile = try WorkdayProfile(reference: reference)
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            #expect(throws: ReferenceTimeError.calendarFailure) {
                try repo.apply(.clockIn(id: UUID(), profile: profile), at: 112, now: 112, expected: ended.version)
            }
            #expect(try store.load() == before)
            let restored = try CatalogRepository(url: url).load(now: 112)
            #expect(restored.catalog.days.last?.profile.reference == nil)
        }
    }

    @Test func `unresolved civil time is preserved instead of inventing a future reference`() throws {
        try withRepository { url, repo in
            let start = try instant("2026-03-07T18:00:00Z")
            let reference = try CapturedReference(
                startedAt: start, timeZoneID: "America/New_York",
                wallTime: ReferenceWallTime(hour: 2, minute: 30, dayOffset: 1)
            )
            let initial = try repo.load(now: start)
            let profile = try WorkdayProfile(reference: reference)
            _ = try repo.apply(
                .clockIn(id: UUID(), profile: profile), at: start, now: start, expected: initial.version
            )
            let reopened = try CatalogRepository(url: url).load(now: start + 1)
            let restored = try #require(reopened.catalog.days.last?.profile.reference)
            #expect(restored.resolution == .nonexistent)
            #expect(restored.referenceAt == nil)
        }
    }
}
