import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct ClockInInteractionTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withController(_ body: (CatalogRepository, inout WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("work.sqlite")
        let repo = try CatalogRepository(url: url, createIfMissing: true)
        let initial = try repo.load(now: 55800)
        let reference = try CapturedReference(startedAt: 55800, timeZoneID: "UTC", wallTime: ReferenceWallTime())
        let started = try repo.apply(
            .clockIn(id: UUID(), profile: WorkdayProfile(reference: reference)),
            at: 55800, now: 55800, expected: initial.version
        )
        _ = try repo.apply(.clockOut(confirmBreak: false), at: 61200, now: 61200, expected: started.version)
        var controller = try WorktimeController(url: url, sample: sample(61210))
        try body(repo, &controller)
    }

    @Test func previewDoesNotSaveAndMovesSummaryPeriod() throws {
        try withController { repo, controller in
            let before = try repo.load(now: 61211)
            let day = try #require(before.catalog.days.last)
            let selection = ClockInSummarySelection(unit: .day, timeZoneID: "Asia/Tokyo")
            let proposal = try controller.previewClockInCorrection(
                expectedDay: day, oldStart: 55800, newStart: 52200, summary: selection, sample: sample(61211)
            )
            #expect(proposal.movesSummaryPeriod)
            #expect(proposal.before.snapshot.bounds.lower == 5400)
            #expect(proposal.after.snapshot.bounds.lower == 9000)
            #expect(proposal.after.day.profile.reference?.logicalDate == day.profile.reference?.logicalDate)
            let earlier = try #require(proposal.summaryImpacts.first)
            let later = try #require(proposal.summaryImpacts.last)
            #expect(earlier.period.end == later.period.start)
            #expect(earlier.before.endedDays == 0)
            #expect(earlier.after.worked == 9000 ... 9000)
            #expect(later.before.worked == 5400 ... 5400)
            #expect(later.after.endedDays == 0)
            #expect(try repo.load(now: 61211).version == before.version)
            #expect(try repo.load(now: 61211).catalog == before.catalog)
            let result = try controller.commitClockInCorrection(proposal, sample: sample(61212))
            #expect(result?.snapshot.bounds.lower == 9000)
            for impact in proposal.summaryImpacts {
                let saved = try controller.summary(period: impact.period, sample: sample(61212))
                #expect(saved.worked == impact.after.worked)
                #expect(saved.endedDays == impact.after.endedDays)
                #expect(saved.target == impact.after.target)
            }
            #expect(!controller.isCurrent(proposal))
            #expect(throws: ClockInInteractionError.staleProposal) {
                try controller.commitClockInCorrection(proposal, sample: sample(61213))
            }
            #expect(try repo.load(now: 61213).catalog.reviewAudit.count == 1)
        }
    }

    @Test func historicalCorrectionPreservesActiveDayAndCheckpoint() throws {
        try withController { repo, controller in
            let ended = try #require(repo.load(now: 61210).catalog.days.last)
            let id = UUID()
            _ = try controller.perform(.clockIn(id: id, profile: WorkdayProfile()), sample: sample(61211))
            let page = try controller.recentHistory(now: 61212)
            let context = try controller.historicalReviewContext(dayID: ended.id, history: page, sample: sample(61212))
            let before = try repo.load(now: 61212)
            let reminders = try controller.reminderState(sample: sample(61212))
            let proposal = try controller.previewClockInCorrection(
                expectedDay: ended, oldStart: 55800, newStart: 56000,
                summary: .init(unit: .week, timeZoneID: "UTC"), historical: context, sample: sample(61212)
            )
            #expect(!proposal.movesSummaryPeriod)
            #expect(proposal.summaryImpacts.count == 1)
            #expect(try repo.load(now: 61212).version == before.version)
            let result = try controller.commitClockInCorrection(proposal, sample: sample(61213))
            let saved = try repo.load(now: 61213)
            #expect(result?.day == before.catalog.days.last)
            #expect(saved.catalog.activeID == id)
            #expect(saved.catalog.days.last == before.catalog.days.last)
            let checkpoint = try #require(repo.loadObservationCheckpoint(expected: saved.version))
            #expect(checkpoint.dayID == id)
            #expect(checkpoint.observedAt == 61213)
            #expect(try controller.reminderState(sample: sample(61213))?.desired == reminders?.desired)
            #expect(!controller.isCurrent(page))
        }
    }

    @Test func observationGapInvalidatesHistoricalProposal() throws {
        try withController { repo, controller in
            let ended = try #require(repo.load(now: 61210).catalog.days.last)
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(61211))
            let page = try controller.recentHistory(now: 61212)
            let context = try controller.historicalReviewContext(dayID: ended.id, history: page, sample: sample(61212))
            let proposal = try controller.previewClockInCorrection(
                expectedDay: ended, oldStart: 55800, newStart: 56000,
                summary: .init(unit: .day, timeZoneID: "UTC"), historical: context, sample: sample(61212)
            )
            let before = try repo.load(now: 61212)
            #expect(throws: ClockInInteractionError.staleProposal) {
                try controller.commitClockInCorrection(proposal, sample: sample(61230))
            }
            #expect(try repo.load(now: 61230).catalog == before.catalog)
            _ = try controller.refresh(sample: sample(61230))
            #expect(!controller.isCurrent(proposal))
            #expect(throws: ClockInInteractionError.staleProposal) {
                try controller.commitClockInCorrection(proposal, sample: sample(61231))
            }
        }
    }
}
