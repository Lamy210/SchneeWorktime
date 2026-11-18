import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CatalogBenchmarkTests {
    private func fixture(days: Int) throws -> Data {
        var journal = CatalogJournal()
        for index in 0 ..< days {
            let start = Int64(index) * 86400 + 36000
            let end = start + 25200
            let command = JournalCommand.clockIn(id: UUID(), target: 25200, expectedRest: 3600)
            journal.events.append(JournalEvent(action: .command(command, at: start), now: start))
            journal.events.append(JournalEvent(action: .command(.clockOut(confirmBreak: false), at: end), now: end))
        }
        return try JSONEncoder().encode(journal)
    }

    private func withFixture(
        days: Int, _ body: (CatalogRepository, CatalogSession, Int64, Int) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("benchmark.sqlite")
        let store = try SnapshotStore(url: url, createIfMissing: true)
        let payload = try fixture(days: days)
        let source = StoredSnapshot(version: StoreVersion(epoch: UUID(), revision: Int64(days * 2)), payload: payload)
        let now = Int64(days) * 86400
        _ = try CatalogBackup.validateSnapshot(source, now: now)
        _ = try store.seedRecovery(source, expected: store.load().version)
        let repository = try CatalogRepository(url: url)
        let cached = try repository.load(now: now)
        try body(repository, cached, now, payload.count)
    }

    @Test func `synthetic benchmark fixture produces equivalent cold and reused catalogs`() throws {
        try withFixture(days: 10) { repository, cached, now, _ in
            #expect(cached.catalog.days.count == 10)
            #expect(cached.version.revision == 20)
            let reused = try repository.revalidate(cached, now: now + 1)
            let fresh = try repository.load(now: now + 1)
            #expect(reused.catalog == fresh.catalog)
            #expect(reused.version == fresh.version)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKTIME_BENCHMARK"] == "1"))
    func `measure journal load and validated reuse with synthetic history`() throws {
        for days in [10, 100, 500] {
            try withFixture(days: days) { repository, cached, now, bytes in
                try measure(repository: repository, cached: cached, now: now, days: days, bytes: bytes)
            }
        }
    }

    private func measure(
        repository: CatalogRepository, cached: CatalogSession, now: Int64, days: Int, bytes: Int
    ) throws {
        let clock = ContinuousClock()
        var loads: [Duration] = []
        var reuses: [Duration] = []
        for _ in 0 ..< 10 {
            let loadStart = clock.now
            let fresh = try repository.load(now: now)
            loads.append(loadStart.duration(to: clock.now))
            let reuseStart = clock.now
            let reused = try repository.revalidate(cached, now: now)
            reuses.append(reuseStart.duration(to: clock.now))
            #expect(fresh.catalog == reused.catalog)
            #expect(fresh.version == reused.version)
        }
        let sortedLoads = loads.sorted()
        let sortedReuses = reuses.sorted()
        let loadMedian = (sortedLoads[4] + sortedLoads[5]) / 2
        let reuseMedian = (sortedReuses[4] + sortedReuses[5]) / 2
        print("WORKTIME_BENCHMARK days=\(days) events=\(days * 2) bytes=\(bytes)")
        print("load_median=\(loadMedian) load_max=\(sortedLoads[9])")
        print("reuse_median=\(reuseMedian) reuse_max=\(sortedReuses[9])")
    }
}
