import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct RestEndInteractionTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withRecordedRest(_ body: (URL, inout WorktimeController, Workday) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("work.sqlite")
        let repo = try CatalogRepository(url: url, createIfMissing: true)
        let id = UUID()
        let initial = try repo.load(now: 39600)
        let started = try repo.apply(.clockIn(id: id, profile: WorkdayProfile()), at: 39600, now: 39600,
                                     expected: initial.version)
        let rest = try repo.apply(.startBreak, at: 43200, now: 43200, expected: started.version)
        let returned = try repo.apply(.endBreak, at: 46800, now: 46800, expected: rest.version)
        try repo.saveObservationCheckpoint(dayID: id, observedAt: 48660, expected: returned.version)
        var controller = try WorktimeController(url: url, sample: sample(48660))
        let day = try #require(returned.catalog.days.last)
        try body(url, &controller, day)
    }

    @Test func `AC10 preview is read only and confirmed correction delays future reminder by thirty minutes`() throws {
        try withRecordedRest { url, controller, day in
            let repo = try CatalogRepository(url: url)
            let before = try repo.load(now: 48661)
            let initial = try controller.reminderState(sample: sample(48661))
            let proposal = try controller.previewRestEndCorrection(
                expectedDay: day, oldEnd: 46800, newEnd: 48600, sample: sample(48661)
            )
            #expect(proposal.before.forecast.goal == .projected(earliestGoalAt: 68400, estimatedDepartureAt: 68400))
            #expect(proposal.after.forecast.goal == .projected(earliestGoalAt: 70200, estimatedDepartureAt: 70200))
            #expect(try repo.load(now: 48661).version == before.version)
            #expect(try controller.reminderState(sample: sample(48661)) == initial)
            let committed = try controller.commitRestEndCorrection(proposal, sample: sample(48662))
            #expect(committed?.forecast.goal == proposal.after.forecast.goal)
            let updated = try controller.reminderState(sample: sample(48662))
            #expect(initial?.desired.map(\.trigger) == [67500])
            #expect(updated?.desired.map(\.trigger) == [69300])
            #expect(updated?.revision == before.version.revision + 1)
            #expect(!controller.isCurrent(proposal))
            #expect(throws: RestEndInteractionError.staleProposal) {
                try controller.commitRestEndCorrection(proposal, sample: sample(48663))
            }
        }
    }

    @Test func `new observation invalidates a recorded rest correction before commit`() throws {
        try withRecordedRest { url, controller, day in
            let proposal = try controller.previewRestEndCorrection(
                expectedDay: day, oldEnd: 46800, newEnd: 48600, sample: sample(48661)
            )
            let repo = try CatalogRepository(url: url)
            let before = try repo.load(now: 48661)
            #expect(throws: RestEndInteractionError.staleProposal) {
                try controller.commitRestEndCorrection(proposal, sample: sample(48700))
            }
            #expect(try repo.load(now: 48700).version == before.version)
            _ = try controller.refresh(sample: sample(48700))
            #expect(!controller.isCurrent(proposal))
        }
    }

    @Test(arguments: [false, true])
    func `historical rest correction preserves current working or resting day`(onBreak: Bool) throws {
        try withRecordedRest { url, controller, day in
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(48662))
            let activeID = UUID()
            _ = try controller.perform(.clockIn(id: activeID, profile: WorkdayProfile()), sample: sample(48700))
            if onBreak {
                _ = try controller.perform(.startBreak, sample: sample(48701))
            }
            let page = try controller.recentHistory(now: 48702)
            let context = try controller.historicalReviewContext(dayID: day.id, history: page, sample: sample(48702))
            let repo = try CatalogRepository(url: url)
            let before = try repo.load(now: 48702)
            let reminder = try controller.reminderState(sample: sample(48702))
            let proposal = try controller.previewRestEndCorrection(
                expectedDay: context.glance.day, oldEnd: 46800, newEnd: 48600,
                historical: context, sample: sample(48702)
            )
            #expect(proposal.before.day.id == day.id)
            #expect(proposal.after.snapshot.recordedRest == 5400)
            #expect(try repo.load(now: 48702).version == before.version)
            let committed = try controller.commitRestEndCorrection(proposal, sample: sample(48703))
            let saved = try repo.load(now: 48703)
            let updated = try controller.reminderState(sample: sample(48703))
            #expect(saved.catalog.activeID == activeID)
            #expect(saved.catalog.days.last == before.catalog.days.last)
            #expect(saved.catalog.observations[activeID] == before.catalog.observations[activeID])
            #expect(committed?.day == before.catalog.days.last)
            #expect(reminder?.desired == updated?.desired)
            #expect(saved.catalog.reviewAudit.last?.dayID == day.id)
            #expect(!controller.isCurrent(page))
            #expect(!controller.isCurrent(context))
            #expect(throws: RestEndInteractionError.staleProposal) {
                try controller.previewRestEndCorrection(
                    expectedDay: context.glance.day, oldEnd: 46800, newEnd: 48600,
                    historical: context, sample: sample(48704)
                )
            }
        }
    }

    @Test func `historical correction requires a current explicit history selection`() throws {
        try withRecordedRest { url, controller, day in
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(48662))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(48700))
            let page = try controller.recentHistory(now: 48701)
            let context = try controller.historicalReviewContext(dayID: day.id, history: page, sample: sample(48701))
            #expect(throws: RestEndInteractionError.staleProposal) {
                try controller.previewRestEndCorrection(
                    expectedDay: context.glance.day, oldEnd: 46800, newEnd: 48600, sample: sample(48701)
                )
            }
            _ = try controller.refresh(sample: sample(48730))
            let repo = try CatalogRepository(url: url)
            let before = try repo.load(now: 48730)
            #expect(throws: RestEndInteractionError.staleProposal) {
                try controller.previewRestEndCorrection(
                    expectedDay: context.glance.day, oldEnd: 46800, newEnd: 48600,
                    historical: context, sample: sample(48731)
                )
            }
            #expect(try repo.load(now: 48731).catalog == before.catalog)
        }
    }
}
