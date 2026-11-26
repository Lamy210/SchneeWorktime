import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ConfirmedReviewTests {
    private func sample(_ now: Int64) throws -> ClockSample {
        try ClockSample(wall: now, uptime: Double(now))
    }

    private func fixture(_ run: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try run(root.appendingPathComponent("worktime.sqlite"))
    }

    private func observedGap(url: URL) throws -> (JournalV2WorktimeController, WorktimeGlance, ObservationGap) {
        var current = try JournalV2WorktimeController(
            url: url, createIfMissing: true, sample: sample(100)
        )
        _ = try current.perform(
            .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
        )
        _ = try current.refresh(sample: sample(110))
        let observed = try current.refresh(sample: sample(140))
        let glance = try #require(observed)
        let gap = try #require(glance.reviewableGaps.first)
        #expect(gap == ObservationGap(start: 110, end: 140))
        return (current, glance, gap)
    }

    @Test func `confirmed partial rest review is audit logged without modifying other unknown intervals`() throws {
        try fixture { url in
            let (initial, glance, gap) = try observedGap(url: url)
            var current = initial
            let context = current.workActionContext
            let selection = try ReviewRangeSelection.selection(
                in: gap, startOffset: 10, endOffset: 20
            )
            let before = try JournalV2Repository(url: url).load(now: 141)
            let proposal = try current.previewConfirmedReview(
                source: gap, selection: selection, classification: .rest,
                matching: context, sample: sample(141)
            )
            #expect(proposal.before.day == glance.day)
            #expect(proposal.after.snapshot.recordedRest == 10)
            let unmodified = try JournalV2Repository(url: url).load(now: 141)
            #expect(unmodified.version == before.version)
            #expect(unmodified.catalog == before.catalog)
            #expect(unmodified.checkpoint == before.checkpoint)
            let result = try current.commitConfirmedReview(
                proposal, matching: context, sample: sample(142)
            )
            #expect(result?.snapshot.recordedRest == 10)
            #expect(result?.reviewableGaps == [
                ObservationGap(start: 110, end: 120),
                ObservationGap(start: 130, end: 140)
            ])
            let saved = try JournalV2Repository(url: url).load(now: 142)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(saved.catalog.reviewAudit.last?.origin == .observation)
            #expect(saved.checkpoint?.observedAt == 142)
            #expect(saved.version == current.version)
        }
    }

    @Test func `whole unknown gap is not treated as work until explicit commit`() throws {
        try fixture { url in
            let (initial, _, gap) = try observedGap(url: url)
            var current = initial
            let expected = current.workActionContext
            let prior = try JournalV2Repository(url: url).load(now: 141)
            let proposal = try current.previewConfirmedReview(
                source: gap, selection: gap, classification: .work,
                matching: expected, sample: sample(141)
            )
            #expect(proposal.after.snapshot.bounds.lower > proposal.before.snapshot.bounds.lower)
            #expect(try JournalV2Repository(url: url).load(now: 141).catalog == prior.catalog)
            _ = try current.commitConfirmedReview(proposal, matching: expected, sample: sample(142))
            let saved = try JournalV2Repository(url: url).load(now: 142)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(try saved.catalog.snapshot(dayID: proposal.before.day.id, now: 142)
                .bounds.lower > proposal.before.snapshot.bounds.lower)
        }
    }

    @Test func `checkpoint-only refresh invalidates an already displayed review confirmation`() throws {
        try fixture { url in
            let (initial, _, gap) = try observedGap(url: url)
            var current = initial
            let displayed = current.workActionContext
            let proposal = try current.previewConfirmedReview(
                source: gap, selection: gap, classification: .rest,
                matching: displayed, sample: sample(141)
            )
            _ = try current.refresh(sample: sample(151))
            #expect(current.version == displayed.version)
            #expect(current.workActionContext != displayed)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try current.commitConfirmedReview(
                    proposal, matching: displayed, sample: sample(152)
                )
            }
            #expect(try JournalV2Repository(url: url).load(now: 152).catalog.reviewAudit.isEmpty)
        }
    }

    @Test func `explicit repreview after normal checkpoint update is read only until new confirmation`() throws {
        try fixture { url in
            let (initial, _, gap) = try observedGap(url: url)
            var current = initial
            let displayed = current.workActionContext
            let old = try current.previewConfirmedReview(
                source: gap, selection: gap, classification: .rest,
                matching: displayed, sample: sample(141)
            )
            _ = try current.refresh(sample: sample(151))
            let fresh = current.workActionContext
            #expect(fresh != displayed)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try current.commitConfirmedReview(old, matching: displayed, sample: sample(152))
            }
            let before = try JournalV2Repository(url: url).load(now: 152)
            let revised = try current.previewConfirmedReview(
                source: gap, selection: gap, classification: .rest,
                matching: fresh, sample: sample(152)
            )
            let afterPreview = try JournalV2Repository(url: url).load(now: 152)
            #expect(afterPreview.version == before.version)
            #expect(afterPreview.checkpoint == before.checkpoint)
            #expect(afterPreview.catalog == before.catalog)
            _ = try current.commitConfirmedReview(revised, matching: fresh, sample: sample(153))
            #expect(try JournalV2Repository(url: url).load(now: 153).catalog.reviewAudit.count == 1)
        }
    }

    @Test func `external checkpoint-only change rejects a current-looking review proposal`() throws {
        try fixture { url in
            let (initial, glance, gap) = try observedGap(url: url)
            var current = initial
            let context = current.workActionContext
            let proposal = try current.previewConfirmedReview(
                source: gap, selection: gap, classification: .rest,
                matching: context, sample: sample(141)
            )
            let repo = try JournalV2Repository(url: url)
            let saved = try repo.load(now: 141)
            let other = try repo.saveObservationCheckpoint(
                dayID: glance.day.id, observedAt: 142, now: 142, matching: saved
            )
            #expect(other.version == saved.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try current.commitConfirmedReview(
                    proposal, matching: context, sample: sample(143)
                )
            }
            let disk = try repo.load(now: 143)
            #expect(disk.checkpoint == other.checkpoint)
            #expect(disk.catalog.reviewAudit.isEmpty)
        }
    }

    @Test func `invalid selection outside the displayed gap is rejected without an event`() throws {
        try fixture { url in
            let (current, _, gap) = try observedGap(url: url)
            let before = try JournalV2Repository(url: url).load(now: 141)
            #expect(throws: JournalV2WorktimeCorrectionError.invalidSelection) {
                try current.previewConfirmedReview(
                    source: gap, selection: ObservationGap(start: 109, end: 130),
                    classification: .work, matching: current.workActionContext,
                    sample: sample(141)
                )
            }
            #expect(try JournalV2Repository(url: url).load(now: 141).catalog == before.catalog)
        }
    }
}
