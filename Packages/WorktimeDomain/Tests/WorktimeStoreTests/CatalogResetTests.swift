import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CatalogResetTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(url, CatalogRepository(url: url, createIfMissing: true))
    }

    @Test func `reset preview is read only and committed reset fences old archive and review`() throws {
        try withRepository { url, repo in
            let store = try SnapshotStore(url: url)
            let initial = try repo.load(now: 100)
            let id = UUID()
            let started = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 110, end: 140), now: 150, expected: started.version
            )
            let proposal = try observed.previewReview(
                dayID: id, selection: .init(start: 110, end: 120), classification: .rest, now: 150
            )
            let reviewed = try repo.commitReview(proposal, now: 150)
            let oldReview = try reviewed.previewReview(
                dayID: id, selection: .init(start: 120, end: 140), classification: .work, now: 150
            )
            let archive = try repo.makeBackup(now: 150, expected: reviewed.version)
            try repo.saveObservationCheckpoint(dayID: id, observedAt: 150, expected: reviewed.version)
            let before = try store.load()
            let reset = try repo.previewReset(now: 150, expected: reviewed.version)
            #expect(reset.workdays == 1)
            #expect(reset.corrections == 1)
            #expect(reset.hasActiveWorkday)
            #expect(try store.load() == before)
            #expect(try repo.loadObservationCheckpoint(expected: reviewed.version) != nil)
            let cleared = try repo.commitReset(reset, now: 150)
            #expect(cleared.version.epoch != reviewed.version.epoch)
            #expect(cleared.version.revision == 0)
            #expect(cleared.catalog == WorkdayCatalog())
            #expect(try repo.loadObservationCheckpoint(expected: cleared.version) == nil)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitReview(oldReview, now: 150)
            }
            #expect(throws: CatalogRollbackError.differentGeneration) {
                try repo.previewRollback(from: archive, now: 150, expected: cleared.version)
            }
            let reopened = try CatalogRepository(url: url).load(now: 150)
            #expect(reopened.version == cleared.version)
            #expect(reopened.catalog == cleared.catalog)
        }
    }

    @Test func `stale reset cannot erase newer records or their observation marker`() throws {
        try withRepository { url, repo in
            let initial = try repo.load(now: 100)
            let reset = try repo.previewReset(now: 100, expected: initial.version)
            let id = UUID()
            let current = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 101, now: 101, expected: initial.version
            )
            try repo.saveObservationCheckpoint(dayID: id, observedAt: 101, expected: current.version)
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitReset(reset, now: 101)
            }
            #expect(try store.load() == before)
            #expect(try repo.loadObservationCheckpoint(expected: current.version)?.dayID == id)
        }
    }
}
