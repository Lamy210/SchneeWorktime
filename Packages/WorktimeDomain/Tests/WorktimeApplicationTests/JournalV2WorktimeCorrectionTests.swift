import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2WorktimeCorrectionTests {
    private func sample(_ at: Int64) throws -> ClockSample {
        try ClockSample(wall: at, uptime: Double(at))
    }

    private func fixture(
        _ body: (URL, JournalV2WorktimeController) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let controller = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        try body(url, controller)
    }

    private func clockIn(_ controller: inout JournalV2WorktimeController, at: Int64) throws -> WorktimeGlance {
        let value = try controller.perform(
            .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(at)
        )
        return try #require(value)
    }

    @Test func `review preview is read only and audit preserves active checkpoint in one commit`() throws {
        try fixture { url, initial in
            var controller = initial
            _ = try clockIn(&controller, at: 100)
            _ = try controller.refresh(sample: sample(110))
            let refreshed = try controller.refresh(sample: sample(140))
            let before = try #require(refreshed)
            let source = try #require(before.reviewableGaps.first)
            let prior = try JournalV2Repository(url: url).load(now: 140)
            let plan = try controller.previewReview(
                expectedDay: before.day, source: source,
                selection: ObservationGap(start: 120, end: 130),
                classification: .rest, sample: sample(145)
            )
            #expect(plan.kind == .observationReview)
            #expect(plan.before.day == before.day)
            #expect(plan.after.snapshot.recordedRest == 10)
            #expect(controller.isCurrent(plan))
            let unchanged = try JournalV2Repository(url: url).load(now: 145)
            #expect(unchanged.version == prior.version)
            #expect(unchanged.catalog == prior.catalog)
            #expect(unchanged.checkpoint == prior.checkpoint)
            _ = try controller.commitCorrection(plan, sample: sample(146))
            let saved = try JournalV2Repository(url: url).load(now: 147)
            #expect(saved.catalog.reviewAudit.count == 1)
            #expect(saved.catalog.reviewAudit.last?.origin == .observationReview)
            #expect(saved.version == controller.version)
            #expect(saved.checkpoint?.observedAt == 146)
            #expect(saved.checkpoint?.dayID == before.day.id)
            #expect(!controller.isCurrent(plan))
            #expect(try JournalV2Repository(url: url).load(now: 147).catalog == saved.catalog)
        }
    }

    @Test func `rest start and end correction commits maintain durable audit sequence`() throws {
        try fixture { url, initial in
            var controller = initial
            _ = try clockIn(&controller, at: 100)
            _ = try controller.perform(.startBreak, sample: sample(110))
            _ = try controller.perform(.endBreak, sample: sample(120))
            let endedResult = try controller.perform(
                .clockOut(confirmBreak: false), sample: sample(130)
            )
            let ended = try #require(endedResult)
            let first = try controller.previewRestBoundaryCorrection(
                expectedDay: ended.day, old: 110, new: 105,
                boundary: .start, sample: sample(135)
            )
            #expect(first.kind == .restStart)
            #expect(first.after.snapshot.recordedRest == 15)
            _ = try controller.commitCorrection(first, sample: sample(136))
            let afterFirst = try JournalV2Repository(url: url).load(now: 136)
            let updatedDay = try #require(afterFirst.catalog.days.last)
            let second = try controller.previewRestBoundaryCorrection(
                expectedDay: updatedDay, old: 120, new: 125,
                boundary: .end, sample: sample(140)
            )
            #expect(second.kind == .restEnd)
            #expect(second.after.snapshot.recordedRest == 20)
            _ = try controller.commitCorrection(second, sample: sample(141))
            let disk = try JournalV2Repository(url: url).load(now: 142)
            #expect(disk.catalog.reviewAudit.map(\.origin) == [.recordedRestStart, .recordedRestEnd])
            #expect(disk.checkpoint == nil)
            #expect(try disk.catalog.snapshot(dayID: ended.day.id, now: 142).recordedRest == 20)
        }
    }

    @Test func `clock in correction retains summary preview and committed original reference audit`() throws {
        try fixture { url, initial in
            var controller = initial
            _ = try clockIn(&controller, at: 100)
            let stoppedResult = try controller.perform(
                .clockOut(confirmBreak: false), sample: sample(110)
            )
            let stopped = try #require(stoppedResult)
            let selection = ClockInSummarySelection(unit: .day, timeZoneID: "UTC")
            let proposal = try controller.previewClockInCorrection(
                expectedDay: stopped.day, oldStart: 100, newStart: 95,
                summary: selection, sample: sample(118)
            )
            #expect(proposal.kind == .clockIn)
            #expect(proposal.summaryImpacts.count == 1)
            #expect(proposal.after.day.intervals.first?.start == 95)
            _ = try controller.commitCorrection(proposal, sample: sample(119))
            let saved = try JournalV2Repository(url: url).load(now: 119)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedClockIn)
            #expect(saved.catalog.reviewAudit.last?.clockInRecord != nil)
            #expect(saved.catalog.days.last?.intervals.first?.start == 95)
            #expect(saved.checkpoint == nil)
        }
    }

    @Test func `a historical ended day can be corrected without losing the current day checkpoint`() throws {
        try fixture { url, initial in
            var controller = initial
            let old = try clockIn(&controller, at: 100)
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(110))
            let active = try clockIn(&controller, at: 120)
            let history = try controller.recentHistory(now: 121)
            let context = try controller.historicalReviewContext(
                dayID: old.day.id, history: history, sample: sample(122)
            )
            #expect(context.glance.day.id == old.day.id)
            let proposal = try controller.previewClockOutCorrection(
                expectedDay: context.glance.day, oldEnd: 110, newEnd: 111,
                historical: context, sample: sample(125)
            )
            #expect(proposal.kind == .clockOut)
            #expect(controller.isCurrent(context))
            let result = try controller.commitCorrection(proposal, sample: sample(126))
            #expect(result?.day.id == active.day.id)
            let saved = try JournalV2Repository(url: url).load(now: 126)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedClockOut)
            #expect(saved.checkpoint?.observedAt == 126)
            #expect(saved.checkpoint?.dayID == active.day.id)
            #expect(saved.catalog.days.first?.intervals.last?.end == 111)
            #expect(saved.catalog.days.last?.id == active.day.id)
            #expect(saved.version == controller.version)
        }
    }

    @Test func `a checkpoint only competitor write invalidates the correction preview`() throws {
        try fixture { url, initial in
            var controller = initial
            let active = try clockIn(&controller, at: 100)
            _ = try controller.refresh(sample: sample(110))
            let currentResult = try controller.refresh(sample: sample(140))
            let current = try #require(currentResult)
            let gap = try #require(current.reviewableGaps.first)
            let proposal = try controller.previewReview(
                expectedDay: current.day, source: gap,
                selection: ObservationGap(start: 120, end: 130),
                classification: .work, sample: sample(141)
            )
            let repository = try JournalV2Repository(url: url)
            let source = try repository.load(now: 141)
            let external = try repository.saveObservationCheckpoint(
                dayID: active.day.id, observedAt: 142, now: 142, matching: source
            )
            #expect(external.version == source.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try controller.commitCorrection(proposal, sample: sample(143))
            }
            let saved = try repository.load(now: 143)
            #expect(saved.checkpoint == external.checkpoint)
            #expect(saved.version == external.version)
            #expect(saved.catalog.reviewAudit.isEmpty)
        }
    }

    @Test func `a stale proposal after another correction cannot be applied twice`() throws {
        try fixture { url, initial in
            var controller = initial
            _ = try clockIn(&controller, at: 100)
            let endedResult = try controller.perform(.clockOut(confirmBreak: false), sample: sample(110))
            let ended = try #require(endedResult)
            let plan = try controller.previewClockOutCorrection(
                expectedDay: ended.day, oldEnd: 110, newEnd: 115, sample: sample(116)
            )
            _ = try controller.commitCorrection(plan, sample: sample(117))
            #expect(!controller.isCurrent(plan))
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try controller.commitCorrection(plan, sample: sample(118))
            }
            let saved = try JournalV2Repository(url: url).load(now: 119)
            #expect(saved.catalog.reviewAudit.count == 1)
        }
    }

    @Test func `sleep gap rejects correction without changing journal or checkpoint`() throws {
        try fixture { url, initial in
            var controller = initial
            _ = try clockIn(&controller, at: 100)
            let endedResult = try controller.perform(.clockOut(confirmBreak: false), sample: sample(110))
            let ended = try #require(endedResult)
            let before = try JournalV2Repository(url: url).load(now: 110)
            #expect(throws: JournalV2WorktimeCorrectionError.staleProposal) {
                try controller.previewClockOutCorrection(
                    expectedDay: ended.day, oldEnd: 110, newEnd: 115, sample: sample(140)
                )
            }
            let after = try JournalV2Repository(url: url).load(now: 140)
            #expect(after.version == before.version)
            #expect(after.catalog == before.catalog)
            #expect(after.checkpoint == before.checkpoint)
        }
    }
}
