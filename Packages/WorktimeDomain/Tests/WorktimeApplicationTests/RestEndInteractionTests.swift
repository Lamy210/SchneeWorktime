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
}
