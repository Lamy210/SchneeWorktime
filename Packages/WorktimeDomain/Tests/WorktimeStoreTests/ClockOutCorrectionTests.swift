import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ClockOutCorrectionTests {
    private func withRepository(_ body: (CatalogRepository, CatalogSession, UUID) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CatalogRepository(url: root.appendingPathComponent("work.sqlite"), createIfMissing: true)
        let id = UUID()
        let initial = try repo.load(now: 100)
        let started = try repo.apply(.clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
                                     expected: initial.version)
        let ended = try repo.apply(.clockOut(confirmBreak: false), at: 200, now: 200, expected: started.version)
        try body(repo, ended, id)
    }

    @Test func `clock out correction preserves audit and replay for earlier and later end`() throws {
        try withRepository { repo, ended, id in
            let preview = try ended.previewClockOutCorrection(dayID: id, oldEnd: 200, newEnd: 180, now: 220)
            #expect(try repo.load(now: 220).version == ended.version)
            let saved = try repo.commitClockOutCorrection(preview, now: 221)
            #expect(saved.catalog.activeID == nil)
            #expect(try saved.catalog.snapshot(dayID: id, now: 221).bounds.lower == 80)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedClockOut)
            #expect(saved.catalog.reviewAudit.last?.review.classification == .gap)
            let later = try saved.previewClockOutCorrection(dayID: id, oldEnd: 180, newEnd: 210, now: 222)
            let revised = try repo.commitClockOutCorrection(later, now: 223)
            #expect(try revised.catalog.snapshot(dayID: id, now: 223).bounds.lower == 110)
            #expect(revised.catalog.reviewAudit.count == 2)
            #expect(revised.catalog.reviewAudit.last?.review.classification == .work)
            #expect(try repo.load(now: 223).catalog == revised.catalog)
            let backup = try repo.makeBackup(now: 223, expected: revised.version)
            #expect(try CatalogBackup.inspect(backup, now: 223).catalog == revised.catalog)
            let csv = try CatalogCSV.encode(revised)
            let text = try #require(String(data: csv, encoding: .utf8))
            #expect(text.contains("clock_out_correction"))
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitClockOutCorrection(preview, now: 224)
            }
        }
    }

    @Test func `historical correction rejects overlap and preserves a later active day`() throws {
        try withRepository { repo, ended, id in
            let activeID = UUID()
            let active = try repo.apply(.clockIn(id: activeID, profile: WorkdayProfile()), at: 250, now: 250,
                                        expected: ended.version)
            #expect(throws: ClockOutCorrectionError.overlapsNextDay) {
                try active.previewClockOutCorrection(dayID: id, oldEnd: 200, newEnd: 251, now: 260)
            }
            for invalid: Int64 in [100, 200, 261] {
                #expect(throws: ClockOutCorrectionError.invalidBoundary) {
                    try active.previewClockOutCorrection(dayID: id, oldEnd: 200, newEnd: invalid, now: 260)
                }
            }
            #expect(try repo.load(now: 260).catalog == active.catalog)
            let preview = try active.previewClockOutCorrection(dayID: id, oldEnd: 200, newEnd: 250, now: 260)
            let saved = try repo.commitClockOutCorrection(preview, now: 261)
            #expect(saved.catalog.days.last == active.catalog.days.last)
            #expect(saved.catalog.activeID == activeID)
        }
    }

    @Test func `shortened clock out does not suppress observations after resume`() throws {
        try withRepository { repo, ended, id in
            let preview = try ended.previewClockOutCorrection(dayID: id, oldEnd: 200, newEnd: 180, now: 220)
            let corrected = try repo.commitClockOutCorrection(preview, now: 221)
            let resumed = try repo.apply(.resume(id: id), at: 180, now: 222, expected: corrected.version)
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 185, end: 195), now: 223, expected: resumed.version
            )
            #expect(observed.catalog.observations[id] == [.init(start: 185, end: 195)])
            #expect(try repo.load(now: 223).catalog == observed.catalog)
        }
    }

    @Test func `uncertain final work is not silently edited and clock out during break remains unsupported`() throws {
        try withRepository { repo, ended, id in
            let resumed = try repo.apply(.resume(id: id), at: 220, now: 220, expected: ended.version)
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 230, end: 240), now: 250, expected: resumed.version
            )
            let closed = try repo.apply(.clockOut(confirmBreak: false), at: 250, now: 250,
                                        expected: observed.version)
            #expect(throws: ClockOutCorrectionError.overlapsUncertainty) {
                try closed.previewClockOutCorrection(dayID: id, oldEnd: 250, newEnd: 235, now: 260)
            }
            let working = try repo.apply(.resume(id: id), at: 260, now: 260, expected: closed.version)
            let rest = try repo.apply(.startBreak, at: 270, now: 270, expected: working.version)
            let final = try repo.apply(.clockOut(confirmBreak: true), at: 280, now: 280, expected: rest.version)
            #expect(throws: ClockOutCorrectionError.invalidBoundary) {
                try final.previewClockOutCorrection(dayID: id, oldEnd: 280, newEnd: 275, now: 290)
            }
            #expect(try repo.load(now: 290).catalog == final.catalog)
        }
    }
}
