import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2CorrectionsTests {
    private func fixture(
        _ body: (URL, JournalV2Repository, UUID, JournalV2Session) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let repository = try JournalV2Repository(url: url, createIfMissing: true)
        let id = UUID()
        let started = try repository.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
            matching: repository.load(now: 100), observedAt: 100
        )
        try body(url, repository, id, started)
    }

    private func ended(
        _ repository: JournalV2Repository, from started: JournalV2Session, now: Int64 = 240
    ) throws -> JournalV2Session {
        try repository.apply(.clockOut(confirmBreak: false), at: now, now: now, matching: started)
    }

    @Test func `reviewed uncertainty persists as an audited event after restart`() throws {
        try fixture { url, repo, id, started in
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 120, end: 160), now: 200, matching: started
            )
            let proposal = try repo.previewReview(
                dayID: id, selection: .init(start: 130, end: 150),
                classification: .rest, now: 205, matching: observed
            )
            #expect(try repo.load(now: 205).version == observed.version)
            let reviewed = try repo.commitReview(proposal, now: 210)
            #expect(reviewed.catalog.reviewAudit.count == 1)
            #expect(try reviewed.catalog.snapshot(dayID: id, now: 211).recordedRest == 20)
            #expect(reviewed.version.revision == observed.version.revision + 1)
            let reopened = try JournalV2Repository(url: url).load(now: 220)
            #expect(reopened.catalog == reviewed.catalog)
            #expect(reopened.version == reviewed.version)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitReview(proposal, now: 221)
            }
        }
    }

    @Test func `checkpoint only update invalidates an old review proposal`() throws {
        try fixture { url, repo, id, started in
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 120, end: 160), now: 200, matching: started
            )
            let proposal = try repo.previewReview(
                dayID: id, selection: .init(start: 130, end: 150),
                classification: .work, now: 200, matching: observed
            )
            let updated = try repo.saveObservationCheckpoint(
                dayID: id, observedAt: 201, now: 201, matching: observed
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repo.commitReview(proposal, now: 202)
            }
            let disk = try JournalV2Repository(url: url).load(now: 203)
            #expect(disk.version == updated.version)
            #expect(disk.checkpoint == updated.checkpoint)
            #expect(disk.catalog.reviewAudit.isEmpty)
        }
    }

    @Test func `rest start and rest end corrections replay from their audit rows`() throws {
        try fixture { url, repo, id, started in
            let onBreak = try repo.apply(.startBreak, at: 200, now: 200, matching: started)
            let returned = try repo.apply(.endBreak, at: 260, now: 260, matching: onBreak)
            let first = try repo.previewRestStartCorrection(
                dayID: id, oldStart: 200, newStart: 170, now: 320, matching: returned
            )
            #expect(throws: RestEndCorrectionError.changedPreview) {
                try repo.commitRestEndCorrection(first, now: 321)
            }
            let adjustedStart = try repo.commitRestStartCorrection(first, now: 321)
            let second = try repo.previewRestEndCorrection(
                dayID: id, oldEnd: 260, newEnd: 290, now: 322, matching: adjustedStart
            )
            let adjustedEnd = try repo.commitRestEndCorrection(second, now: 323)
            #expect(adjustedEnd.catalog.reviewAudit.count == 2)
            #expect(adjustedEnd.catalog.reviewAudit[0].origin == .recordedRestStart)
            #expect(adjustedEnd.catalog.reviewAudit[1].origin == .recordedRestEnd)
            #expect(try adjustedEnd.catalog.snapshot(dayID: id, now: 330).recordedRest == 120)
            #expect(try JournalV2Repository(url: url).load(now: 330).catalog == adjustedEnd.catalog)
        }
    }

    @Test func `clock out correction preserves the ended workday audit`() throws {
        try fixture { url, repo, id, started in
            let finished = try ended(repo, from: started)
            let proposal = try repo.previewClockOutCorrection(
                dayID: id, oldEnd: 240, newEnd: 260, now: 300, matching: finished
            )
            let revised = try repo.commitClockOutCorrection(proposal, now: 301)
            #expect(revised.catalog.reviewAudit.last?.origin == .recordedClockOut)
            #expect(revised.catalog.activeID == nil)
            #expect(try revised.catalog.snapshot(dayID: id, now: 301).bounds.lower == 160)
            #expect(try JournalV2Repository(url: url).load(now: 302).catalog == revised.catalog)
        }
    }

    @Test func `clock in correction keeps the captured reference record and audit`() throws {
        try fixture { url, repo, id, started in
            let finished = try ended(repo, from: started)
            let proposal = try repo.previewClockInCorrection(
                dayID: id, oldStart: 100, newStart: 80, now: 300, matching: finished
            )
            let revised = try repo.commitClockInCorrection(proposal, now: 301)
            #expect(revised.catalog.reviewAudit.last?.origin == .recordedClockIn)
            #expect(revised.catalog.reviewAudit.last?.clockInRecord == proposal.preview.record)
            #expect(try revised.catalog.snapshot(dayID: id, now: 301).bounds.lower == 160)
            #expect(try JournalV2Repository(url: url).load(now: 302).catalog == revised.catalog)
        }
    }

    @Test func `reset epoch rejects pending correction proposal without writing`() throws {
        try fixture { url, repo, id, started in
            let finished = try ended(repo, from: started)
            let proposal = try repo.previewClockOutCorrection(
                dayID: id, oldEnd: 240, newEnd: 260, now: 300, matching: finished
            )
            let preview = try repo.previewReset(now: 301, matching: finished)
            let reset = try repo.commitReset(preview, now: 302)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.commitClockOutCorrection(proposal, now: 303)
            }
            #expect(try JournalV2Repository(url: url).load(now: 303).version == reset.version)
            #expect(try repo.load(now: 303).catalog.days.isEmpty)
        }
    }
}
