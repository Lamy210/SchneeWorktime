import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CatalogRepositoryTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(url, CatalogRepository(url: url, createIfMissing: true))
    }

    private func clockIn(_ repo: CatalogRepository, id: UUID) throws -> CatalogSession {
        let empty = try repo.load(now: 100)
        let profile = try WorkdayProfile()
        return try repo.apply(.clockIn(id: id, profile: profile), at: 100,
                              now: 100, expected: empty.version)
    }

    @Test func `reopen restores attendance review and audit`() throws {
        try withRepository { url, repo in
            let id = UUID()
            let start = try clockIn(repo, id: id)
            let observed = try repo.recordObservation(dayID: id, gap: .init(start: 120, end: 160),
                                                      now: 200, expected: start.version)
            let preview = try observed.catalog.previewReview(
                dayID: id, selection: .init(start: 130, end: 150), classification: .rest, now: 200
            )
            let reviewed = try repo.commitReview(preview, now: 210, expected: observed.version)
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 220,
                                       now: 220, expected: reviewed.version)
            let restored = try CatalogRepository(url: url).load(now: 300)
            #expect(restored.catalog == ended.catalog)
            #expect(restored.version == ended.version)
            #expect(restored.catalog.reviewAudit.count == 1)
            #expect(restored.catalog.activeID == nil)
            let totals = try restored.catalog.snapshot(dayID: id, now: 300)
            #expect(totals.bounds.lower == 80)
            #expect(totals.bounds.upper == 100)
            #expect(totals.recordedRest == 20)
        }
    }

    @Test func `stale independent repository cannot append`() throws {
        try withRepository { url, first in
            let second = try CatalogRepository(url: url)
            let before = try second.load(now: 100)
            let start = try clockIn(first, id: UUID())
            let profile = try WorkdayProfile()
            #expect(throws: SnapshotStoreError.staleVersion) {
                try second.apply(.clockIn(id: UUID(), profile: profile), at: 100,
                                 now: 100, expected: before.version)
            }
            #expect(try second.load(now: 100).catalog == start.catalog)
        }
    }

    @Test func `duplicate observation does not append a durable event`() throws {
        try withRepository { _, repo in
            let id = UUID()
            let start = try clockIn(repo, id: id)
            let gap = ObservationGap(start: 110, end: 120)
            let first = try repo.recordObservation(dayID: id, gap: gap, now: 130, expected: start.version)
            let second = try repo.recordObservation(dayID: id, gap: gap, now: 130, expected: first.version)
            #expect(second.version == first.version)
            #expect(second.catalog == first.catalog)
        }
    }

    @Test func `invalid command leaves persisted snapshot unchanged`() throws {
        try withRepository { _, repo in
            let start = try clockIn(repo, id: UUID())
            #expect(throws: WorkdayError.zeroLengthInterval) {
                try repo.apply(.clockOut(confirmBreak: false), at: 100, now: 100, expected: start.version)
            }
            let restored = try repo.load(now: 100)
            #expect(restored.version == start.version)
            #expect(restored.catalog == start.catalog)
        }
    }

    @Test func `replay rejects malformed and impossible history`() throws {
        try withRepository { url, repo in
            let store = try SnapshotStore(url: url)
            let empty = try store.load()
            let invalid = CatalogJournal(events: [.init(action: .command(.startBreak, at: 100), now: 100)])
            let encoded = try JSONEncoder().encode(invalid)
            let version = try store.save(encoded, expected: empty.version)
            #expect(throws: WorkdayError.noActiveDay) { try repo.load(now: 100) }
            let bad = Data("invalid JSON".utf8)
            _ = try store.save(bad, expected: version)
            #expect(throws: CatalogPersistenceError.invalidJournal) { try repo.load(now: 100) }
            #expect(try store.load().payload == bad)
        }
    }

    @Test func `replay fails closed for future recorded event`() throws {
        try withRepository { _, repo in
            let start = try clockIn(repo, id: UUID())
            #expect(throws: CatalogPersistenceError.futureEvent) { try repo.load(now: 99) }
            #expect(try repo.load(now: 100).version == start.version)
        }
    }
}
