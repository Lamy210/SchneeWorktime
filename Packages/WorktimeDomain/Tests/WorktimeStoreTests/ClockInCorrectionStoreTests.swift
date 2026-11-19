import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ClockInCorrectionStoreTests {
    private func withRepository(_ body: (CatalogRepository, CatalogSession, UUID) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CatalogRepository(url: root.appendingPathComponent("work.sqlite"), createIfMissing: true)
        let id = UUID()
        let initial = try repo.load(now: 3600)
        let reference = try CapturedReference(startedAt: 3600, timeZoneID: "UTC", wallTime: ReferenceWallTime())
        let profile = try WorkdayProfile(reference: reference)
        let started = try repo.apply(.clockIn(id: id, profile: profile), at: 3600, now: 3600,
                                     expected: initial.version)
        let ended = try repo.apply(.clockOut(confirmBreak: false), at: 7200, now: 7200, expected: started.version)
        try body(repo, ended, id)
    }

    @Test func `start correction retains reference evidence and round trips backup and journal`() throws {
        try withRepository { repo, ended, id in
            let preview = try ended.previewClockInCorrection(dayID: id, oldStart: 3600, newStart: 1800, now: 7300)
            #expect(try repo.load(now: 7300).version == ended.version)
            let saved = try repo.commitClockInCorrection(preview, now: 7301)
            #expect(try saved.catalog.snapshot(dayID: id, now: 7301).bounds.lower == 5400)
            let audit = try #require(saved.catalog.reviewAudit.last)
            #expect(audit.origin == .recordedClockIn)
            #expect(audit.clockInRecord == preview.preview.record)
            let later = try saved.previewClockInCorrection(dayID: id, oldStart: 1800, newStart: 4000, now: 7302)
            let revised = try repo.commitClockInCorrection(later, now: 7303)
            #expect(revised.catalog.reviewAudit.count == 2)
            #expect(try repo.load(now: 7303).catalog == revised.catalog)
            let backup = try repo.makeBackup(now: 7303, expected: revised.version)
            #expect(try CatalogBackup.inspect(backup, now: 7303).catalog == revised.catalog)
            let csv = try CatalogCSV.encode(revised)
            let text = try #require(String(data: csv, encoding: .utf8))
            #expect(text.contains("clock_in_correction"))
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitClockInCorrection(preview, now: 7304)
            }
        }
    }

    @Test func `historical start correction keeps later active day intact`() throws {
        try withRepository { repo, ended, id in
            let activeID = UUID()
            let active = try repo.apply(.clockIn(id: activeID, profile: WorkdayProfile()), at: 7400, now: 7400,
                                        expected: ended.version)
            let preview = try active.previewClockInCorrection(dayID: id, oldStart: 3600, newStart: 4000, now: 7500)
            let saved = try repo.commitClockInCorrection(preview, now: 7501)
            #expect(saved.catalog.activeID == activeID)
            #expect(saved.catalog.days.last == active.catalog.days.last)
            #expect(saved.catalog.observations[activeID] == active.catalog.observations[activeID])
            #expect(try repo.load(now: 7501).catalog == saved.catalog)
        }
    }

    @Test func `journal replay rejects changed captured wall time and preserves original state`() throws {
        try withRepository { _, ended, id in
            var catalog = ended.catalog
            let before = catalog
            let reference = try #require(catalog.days.last?.profile.reference)
            let changed = try CapturedReference(
                startedAt: 1800, timeZoneID: "UTC", wallTime: ReferenceWallTime(hour: 19)
            )
            let record = ClockInCorrectionRecord(
                dayID: id, oldStart: 3600, newStart: 1800, beforeReference: reference, afterReference: changed
            )
            let event = JournalEvent(action: .correctClockIn(record), now: 7300)
            #expect(throws: ClockInCorrectionError.changesReference) {
                try event.apply(to: &catalog)
            }
            #expect(catalog == before)
        }
    }
}
