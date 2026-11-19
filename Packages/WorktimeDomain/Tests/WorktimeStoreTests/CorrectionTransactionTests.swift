import CSQLite
import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CorrectionTransactionTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(url, CatalogRepository(url: url, createIfMissing: true))
    }

    private func execute(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(handle) }
        guard status == SQLITE_OK, let handle else { throw SnapshotStoreError.sqlite(status) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw SnapshotStoreError.sqlite(result) }
    }

    private func rejectWrites(at url: URL) throws {
        // FAIL preserves the row UPDATE within the transaction until ROLLBACK.
        try execute("""
        CREATE TRIGGER reject_snapshot_update AFTER UPDATE ON snapshot
        BEGIN SELECT RAISE(FAIL, 'injected write failure'); END
        """, at: url)
    }

    @Test func `failed observation review leaves exact journal and checkpoint then retries once`() throws {
        try withRepository { url, repo in
            let id = UUID()
            let initial = try repo.load(now: 100)
            let started = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let gap = ObservationGap(start: 120, end: 140)
            let observed = try repo.recordObservation(dayID: id, gap: gap, now: 150, expected: started.version)
            try repo.saveObservationCheckpoint(dayID: id, observedAt: 150, expected: observed.version)
            let proposal = try observed.previewReview(dayID: id, selection: gap, classification: .rest, now: 150)
            let marker = try repo.loadObservationCheckpoint(expected: observed.version)
            try rejectWrites(at: url)
            #expect(throws: SnapshotStoreError.sqlite(SQLITE_CONSTRAINT)) {
                try repo.commitReview(proposal, now: 151)
            }
            let reopened = try CatalogRepository(url: url).load(now: 151)
            #expect(reopened.validatedSnapshot == observed.validatedSnapshot)
            #expect(reopened.catalog == observed.catalog)
            #expect(try repo.loadObservationCheckpoint(expected: observed.version) == marker)
            try execute("DROP TRIGGER reject_snapshot_update", at: url)
            let saved = try repo.commitReview(proposal, now: 152)
            #expect(saved.version.revision == observed.version.revision + 1)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(saved.catalog.observations[id]?.isEmpty == true)
            #expect(try saved.catalog.snapshot(dayID: id, now: 152).recordedRest == 20)
            #expect(try CatalogRepository(url: url).load(now: 152).catalog == saved.catalog)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitReview(proposal, now: 153)
            }
        }
    }

    @Test func `failed clock out correction preserves original history and audit then retries once`() throws {
        try withRepository { url, repo in
            let id = UUID()
            let initial = try repo.load(now: 100)
            let started = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 200, now: 200, expected: started.version)
            let proposal = try ended.previewClockOutCorrection(dayID: id, oldEnd: 200, newEnd: 180, now: 210)
            try rejectWrites(at: url)
            #expect(throws: SnapshotStoreError.sqlite(SQLITE_CONSTRAINT)) {
                try repo.commitClockOutCorrection(proposal, now: 211)
            }
            let reopened = try CatalogRepository(url: url).load(now: 211)
            #expect(reopened.validatedSnapshot == ended.validatedSnapshot)
            #expect(reopened.catalog == ended.catalog)
            #expect(reopened.catalog.reviewAudit.isEmpty)
            try execute("DROP TRIGGER reject_snapshot_update", at: url)
            let saved = try repo.commitClockOutCorrection(proposal, now: 212)
            #expect(saved.version.revision == ended.version.revision + 1)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedClockOut)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(try saved.catalog.snapshot(dayID: id, now: 212).bounds.lower == 80)
            #expect(try CatalogRepository(url: url).load(now: 212).catalog == saved.catalog)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitClockOutCorrection(proposal, now: 213)
            }
        }
    }

    @Test func `failed clock in correction preserves captured reference and later active day`() throws {
        try withRepository { url, repo in
            let id = UUID()
            let activeID = UUID()
            let reference = try CapturedReference(startedAt: 3600, timeZoneID: "UTC", wallTime: ReferenceWallTime())
            let initial = try repo.load(now: 3600)
            let started = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile(reference: reference)),
                at: 3600, now: 3600, expected: initial.version
            )
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 7200, now: 7200, expected: started.version)
            let active = try repo.apply(
                .clockIn(id: activeID, profile: WorkdayProfile()), at: 7400, now: 7400, expected: ended.version
            )
            try repo.saveObservationCheckpoint(dayID: activeID, observedAt: 7500, expected: active.version)
            let marker = try #require(try repo.loadObservationCheckpoint(expected: active.version))
            let proposal = try active.previewClockInCorrection(dayID: id, oldStart: 3600, newStart: 1800, now: 7500)
            try rejectWrites(at: url)
            #expect(throws: SnapshotStoreError.sqlite(SQLITE_CONSTRAINT)) {
                try repo.commitClockInCorrection(proposal, now: 7501)
            }
            let reopened = try CatalogRepository(url: url).load(now: 7501)
            #expect(reopened.validatedSnapshot == active.validatedSnapshot)
            #expect(reopened.catalog == active.catalog)
            #expect(reopened.catalog.days.first?.profile.reference == reference)
            #expect(try repo.loadObservationCheckpoint(expected: active.version) == marker)
            try execute("DROP TRIGGER reject_snapshot_update", at: url)
            let saved = try repo.commitClockInCorrection(proposal, now: 7502)
            #expect(saved.version.revision == active.version.revision + 1)
            #expect(saved.catalog.activeID == activeID)
            #expect(saved.catalog.days.last == active.catalog.days.last)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(saved.catalog.reviewAudit.last?.clockInRecord == proposal.preview.record)
            #expect(try saved.catalog.snapshot(dayID: id, now: 7502).bounds.lower == 5400)
            #expect(try CatalogRepository(url: url).load(now: 7502).catalog == saved.catalog)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitClockInCorrection(proposal, now: 7503)
            }
        }
    }
}
