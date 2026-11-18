import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct RestEndCorrectionTests {
    private func withRepository(_ body: (CatalogRepository, CatalogSession, UUID) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try CatalogRepository(url: directory.appendingPathComponent("work.sqlite"), createIfMissing: true)
        let id = UUID()
        let initial = try repo.load(now: 100)
        let started = try repo.apply(.clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
                                     expected: initial.version)
        let rest = try repo.apply(.startBreak, at: 200, now: 200, expected: started.version)
        let returned = try repo.apply(.endBreak, at: 260, now: 260, expected: rest.version)
        try body(repo, returned, id)
    }

    @Test func `recorded rest end correction changes work and rest and survives replay with audit`() throws {
        try withRepository { repo, returned, id in
            let preview = try returned.previewRestEndCorrection(dayID: id, oldEnd: 260, newEnd: 290, now: 320)
            #expect(try repo.load(now: 320).version == returned.version)
            let saved = try repo.commitRestEndCorrection(preview, now: 321)
            let snapshot = try saved.catalog.snapshot(dayID: id, now: 321)
            #expect(snapshot.bounds.lower == 131)
            #expect(snapshot.recordedRest == 90)
            #expect(saved.catalog.activeID == id)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedRestEnd)
            #expect(saved.catalog.reviewAudit.last?.review.beforeIntervals == returned.catalog.days.first?.intervals)
            #expect(try repo.load(now: 321).catalog == saved.catalog)
            let backup = try repo.makeBackup(now: 321, expected: saved.version)
            #expect(try CatalogBackup.inspect(backup, now: 321).catalog == saved.catalog)
            let csv = try CatalogCSV.encode(saved)
            let text = try #require(String(data: csv, encoding: .utf8))
            #expect(text.contains("rest_end_correction"))
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitRestEndCorrection(preview, now: 322)
            }
            #expect(try repo.load(now: 322).version == saved.version)
        }
    }

    @Test func `invalid boundaries and uncertain work do not mutate catalog`() throws {
        try withRepository { repo, returned, id in
            #expect(throws: RestEndCorrectionError.invalidBoundary) {
                try returned.previewRestEndCorrection(dayID: id, oldEnd: 260, newEnd: 200, now: 320)
            }
            #expect(throws: RestEndCorrectionError.invalidBoundary) {
                try returned.previewRestEndCorrection(dayID: id, oldEnd: 260, newEnd: 320, now: 320)
            }
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 270, end: 280), now: 320, expected: returned.version
            )
            #expect(throws: RestEndCorrectionError.overlapsUncertainty) {
                try observed.previewRestEndCorrection(dayID: id, oldEnd: 260, newEnd: 290, now: 320)
            }
            #expect(try repo.load(now: 320).catalog == observed.catalog)
            #expect(observed.catalog.reviewAudit.isEmpty)
        }
    }

    @Test func `historical rest shortening preserves the active day and rejects old epoch`() throws {
        try withRepository { repo, returned, id in
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 330, now: 330, expected: returned.version)
            let currentID = UUID()
            let active = try repo.apply(.clockIn(id: currentID, profile: WorkdayProfile()), at: 400, now: 400,
                                        expected: ended.version)
            let preview = try active.previewRestEndCorrection(dayID: id, oldEnd: 260, newEnd: 250, now: 410)
            let saved = try repo.commitRestEndCorrection(preview, now: 411)
            #expect(saved.catalog.activeID == currentID)
            #expect(saved.catalog.days.last == active.catalog.days.last)
            #expect(try saved.catalog.snapshot(dayID: id, now: 411).recordedRest == 50)
            let stale = try saved.previewRestEndCorrection(dayID: id, oldEnd: 250, newEnd: 240, now: 412)
            let reset = try repo.previewReset(now: 412, expected: saved.version)
            _ = try repo.commitReset(reset, now: 413)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitRestEndCorrection(stale, now: 414)
            }
            #expect(try repo.load(now: 414).catalog.days.isEmpty)
        }
    }
}
