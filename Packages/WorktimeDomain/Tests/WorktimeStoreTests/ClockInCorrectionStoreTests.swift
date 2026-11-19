import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ClockInCorrectionStoreTests {
    private func withRepository(
        captureReference: Bool = true, _ body: (CatalogRepository, CatalogSession, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CatalogRepository(url: root.appendingPathComponent("work.sqlite"), createIfMissing: true)
        let id = UUID()
        let initial = try repo.load(now: 3600)
        let reference: CapturedReference? = if captureReference {
            try CapturedReference(startedAt: 3600, timeZoneID: "UTC", wallTime: ReferenceWallTime())
        } else {
            nil
        }
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

    @Test func `replay does not resolve a recorded timezone using current timezone rules`() throws {
        let unavailableZone = "SchneeWorktime/UnavailableZone"
        #expect(TimeZone(identifier: unavailableZone) == nil)
        let before = try unavailableReference(at: 3600, zone: unavailableZone)
        let after = try unavailableReference(at: 1800, zone: unavailableZone)
        let id = UUID()
        var catalog = WorkdayCatalog()
        try catalog.apply(.clockIn(id: id, profile: WorkdayProfile(reference: before)),
                          at: 3600, now: 3600, expectedRevision: 0)
        try catalog.apply(.clockOut(confirmBreak: false), at: 7200, now: 7200, expectedRevision: 1)
        let record = ClockInCorrectionRecord(
            dayID: id, oldStart: 3600, newStart: 1800, beforeReference: before, afterReference: after
        )
        let event = JournalEvent(action: .correctClockIn(record), now: 7300)
        let encoded = try JSONEncoder().encode(event)
        try JSONDecoder().decode(JournalEvent.self, from: encoded).apply(to: &catalog)
        #expect(catalog.days.last?.profile.reference == after)
        #expect(catalog.reviewAudit.last?.clockInRecord == record)
        #expect(try catalog.snapshot(dayID: id, now: 7300).bounds.lower == 5400)
    }

    private func unavailableReference(at start: Int64, zone: String) throws -> CapturedReference {
        let reference = try CapturedReference(startedAt: start, timeZoneID: "UTC", wallTime: ReferenceWallTime())
        let encoded = try JSONEncoder().encode(reference)
        var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields["timeZoneID"] = zone
        return try JSONDecoder().decode(CapturedReference.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func `clock in correction alone never suppresses later observations`() throws {
        try withRepository { repo, ended, id in
            let preview = try ended.previewClockInCorrection(dayID: id, oldStart: 3600, newStart: 4000, now: 7300)
            let saved = try repo.commitClockInCorrection(preview, now: 7301)
            let resumed = try repo.apply(.resume(id: id), at: 7400, now: 7400, expected: saved.version)
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 3700, end: 7500), now: 7500, expected: resumed.version
            )
            #expect(observed.catalog.observations[id] == [.init(start: 3700, end: 7500)])
            #expect(try repo.load(now: 7500).catalog == observed.catalog)
        }
    }

    @Test func `legacy start correction retains unknown reference in audit and backup`() throws {
        try withRepository(captureReference: false) { repo, ended, id in
            let preview = try ended.previewClockInCorrection(dayID: id, oldStart: 3600, newStart: 1800, now: 7300)
            let corrected = try repo.commitClockInCorrection(preview, now: 7301)
            let restored = try repo.load(now: 7301)
            let record = try #require(restored.catalog.reviewAudit.last?.clockInRecord)
            #expect(restored.catalog.days.last?.profile.reference == nil)
            #expect(record.beforeReference == nil)
            #expect(record.afterReference == nil)
            #expect(try restored.catalog.snapshot(dayID: id, now: 7301).bounds.lower == 5400)
            let backup = try repo.makeBackup(now: 7301, expected: corrected.version)
            #expect(try CatalogBackup.inspect(backup, now: 7301).catalog == corrected.catalog)
        }
    }

    @Test func `same version with different valid source bytes cannot commit start correction`() throws {
        try withRepository { repo, ended, id in
            let original = ended.validatedSnapshot
            let payload = try #require(original.payload)
            let alternate = StoredSnapshot(version: original.version, payload: payload + Data([0x20]))
            let session = try CatalogBackup.validateSnapshot(alternate, now: 7300)
            #expect(session.catalog == ended.catalog)
            #expect(session.version == ended.version)
            let proposal = try session.previewClockInCorrection(
                dayID: id, oldStart: 3600, newStart: 1800, now: 7300
            )
            #expect(throws: CatalogPersistenceError.invalidJournal) {
                try repo.commitClockInCorrection(proposal, now: 7301)
            }
            #expect(try repo.load(now: 7301).validatedSnapshot == original)
        }
    }
}
