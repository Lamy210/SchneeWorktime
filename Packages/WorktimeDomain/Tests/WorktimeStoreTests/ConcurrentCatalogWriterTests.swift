import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

private actor CatalogRaceGate {
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        if let first = waiting {
            waiting = nil
            first.resume()
        } else {
            await withCheckedContinuation { waiting = $0 }
        }
    }
}

private enum CatalogWriteOutcome: Sendable, Equatable {
    case committed(StoreVersion)
    case stale
    case unexpected(String)
}

struct ConcurrentCatalogWriterTests {
    private func attempt(_ operation: () throws -> CatalogSession) -> CatalogWriteOutcome {
        do {
            return try .committed(operation().version)
        } catch SnapshotStoreError.staleVersion {
            return .stale
        } catch {
            return .unexpected(String(describing: error))
        }
    }

    private func race(
        _ first: @escaping @Sendable () throws -> CatalogSession,
        _ second: @escaping @Sendable () throws -> CatalogSession
    ) async -> [CatalogWriteOutcome] {
        let gate = CatalogRaceGate()
        return await withTaskGroup(of: CatalogWriteOutcome.self) { group in
            group.addTask {
                await gate.wait()
                return attempt(first)
            }
            group.addTask {
                await gate.wait()
                return attempt(second)
            }
            var outcomes: [CatalogWriteOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    @Test func `competing clock ins preserve exactly one active workday`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let first = try CatalogRepository(url: url, createIfMissing: true)
        let second = try CatalogRepository(url: url)
        let version = try first.load(now: 100).version
        #expect(try second.load(now: 100).version == version)
        let firstID = UUID()
        let secondID = UUID()
        let profile = try WorkdayProfile()
        let outcomes = await race({
            try first.apply(.clockIn(id: firstID, profile: profile), at: 100, now: 100, expected: version)
        }, {
            try second.apply(.clockIn(id: secondID, profile: profile), at: 100, now: 100, expected: version)
        })
        let reopened = try CatalogRepository(url: url).load(now: 101)
        #expect(outcomes.count == 2)
        #expect(outcomes.filter { $0 == .stale }.count == 1)
        #expect(outcomes.filter { $0 == .committed(reopened.version) }.count == 1)
        #expect(reopened.version.epoch == version.epoch)
        #expect(reopened.version.revision == version.revision + 1)
        #expect(reopened.catalog.days.count == 1)
        let activeID = try #require(reopened.catalog.activeID)
        #expect([firstID, secondID].contains(activeID))
        #expect(reopened.catalog.days.first?.id == activeID)
        #expect(try second.load(now: 101).validatedSnapshot == reopened.validatedSnapshot)
    }

    @Test func `concurrent reset and clock in cannot resurrect the erased generation`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let first = try CatalogRepository(url: url, createIfMissing: true)
        let second = try CatalogRepository(url: url)
        let initial = try first.load(now: 100)
        let profile = try WorkdayProfile()
        let started = try first.apply(
            .clockIn(id: UUID(), profile: profile), at: 100, now: 100, expected: initial.version
        )
        let ended = try first.apply(.clockOut(confirmBreak: false), at: 200, now: 200, expected: started.version)
        let proposal = try first.previewReset(now: 210, expected: ended.version)
        let id = UUID()
        let outcomes = await race({
            try first.commitReset(proposal, now: 210)
        }, {
            try second.apply(.clockIn(id: id, profile: profile), at: 210, now: 210, expected: ended.version)
        })
        let reopened = try CatalogRepository(url: url).load(now: 211)
        #expect(outcomes.count == 2)
        #expect(outcomes.filter { $0 == .stale }.count == 1)
        #expect(outcomes.filter { $0 == .committed(reopened.version) }.count == 1)
        if reopened.version.epoch == ended.version.epoch {
            #expect(reopened.version.revision == ended.version.revision + 1)
            #expect(reopened.catalog.days.count == 2)
            #expect(reopened.catalog.days.first == ended.catalog.days.first)
            #expect(reopened.catalog.activeID == id)
        } else {
            #expect(reopened.version.revision == 0)
            #expect(reopened.catalog == WorkdayCatalog())
            #expect(reopened.validatedSnapshot.payload == nil)
        }
        #expect(throws: SnapshotStoreError.staleVersion) {
            try second.apply(.clockIn(id: UUID(), profile: profile), at: 212, now: 212, expected: ended.version)
        }
        #expect(try first.load(now: 212).validatedSnapshot == reopened.validatedSnapshot)
    }
}
