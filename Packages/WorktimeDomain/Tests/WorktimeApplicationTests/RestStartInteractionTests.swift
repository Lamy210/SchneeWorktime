import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct RestStartInteractionTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withController(_ body: (URL, inout WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("work.sqlite")
        let repo = try CatalogRepository(url: url, createIfMissing: true)
        let initial = try repo.load(now: 39600)
        let id = UUID()
        let started = try repo.apply(.clockIn(id: id, profile: WorkdayProfile()), at: 39600, now: 39600,
                                     expected: initial.version)
        let rest = try repo.apply(.startBreak, at: 43200, now: 43200, expected: started.version)
        let returned = try repo.apply(.endBreak, at: 46800, now: 46800, expected: rest.version)
        try repo.saveObservationCheckpoint(dayID: id, observedAt: 48660, expected: returned.version)
        var controller = try WorktimeController(url: url, sample: sample(48660))
        try body(url, &controller)
    }

    @Test func `earlier rest start delays goal and reminder only after confirmation`() throws {
        try withController { url, controller in
            let repo = try CatalogRepository(url: url)
            let before = try repo.load(now: 48661)
            let day = try #require(before.catalog.days.last)
            let notification = try controller.reminderState(sample: sample(48661))
            let proposal = try controller.previewRestBoundaryCorrection(
                expectedDay: day, old: 43200, new: 41400, boundary: .start, sample: sample(48661)
            )
            #expect(proposal.boundary == .start)
            #expect(proposal.after.snapshot.recordedRest == 5400)
            #expect(proposal.after.forecast.goal == .projected(earliestGoalAt: 70200, estimatedDepartureAt: 70200))
            #expect(try controller.reminderState(sample: sample(48661)) == notification)
            #expect(try repo.load(now: 48661).version == before.version)
            #expect(throws: RestEndInteractionError.staleProposal) {
                try controller.commitRestEndCorrection(proposal, sample: sample(48662))
            }
            let committed = try controller.commitRestBoundaryCorrection(proposal, sample: sample(48662))
            #expect(committed?.forecast.goal == proposal.after.forecast.goal)
            let updated = try controller.reminderState(sample: sample(48662))
            #expect(notification?.desired.map(\.trigger) == [67500])
            #expect(updated?.desired.map(\.trigger) == [69300])
            #expect(!controller.isCurrent(proposal))
            #expect(try repo.load(now: 48662).catalog.reviewAudit.last?.origin == .recordedRestStart)
        }
    }

    @Test func `ongoing break start correction keeps the break open and refuses stale confirmation`() throws {
        try withController { url, controller in
            let opened = try controller.perform(.startBreak, sample: sample(48661))
            let day = try #require(opened?.day)
            let proposal = try controller.previewRestBoundaryCorrection(
                expectedDay: day, old: 48661, new: 48655, boundary: .start, sample: sample(48662)
            )
            #expect(proposal.after.day.state == .onBreak)
            let committed = try controller.commitRestBoundaryCorrection(proposal, sample: sample(48663))
            #expect(committed?.day.intervals.last == .init(start: 48655, end: nil, kind: .rest))
            #expect(committed?.day.state == .onBreak)
            let repo = try CatalogRepository(url: url)
            let saved = try repo.load(now: 48663)
            #expect(throws: RestEndInteractionError.staleProposal) {
                try controller.commitRestBoundaryCorrection(proposal, sample: sample(48664))
            }
            #expect(try repo.load(now: 48664).catalog == saved.catalog)
        }
    }
}
