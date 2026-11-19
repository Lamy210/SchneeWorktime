import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct ClockOutInteractionTests {
    private func sample(_ second: Int64) throws -> ClockSample {
        try ClockSample(wall: second, uptime: Double(second))
    }

    private func withController(_ body: (CatalogRepository, inout WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("work.sqlite")
        let repo = try CatalogRepository(url: url, createIfMissing: true)
        let initial = try repo.load(now: 100)
        let started = try repo.apply(.clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100,
                                     expected: initial.version)
        _ = try repo.apply(.clockOut(confirmBreak: false), at: 200, now: 200, expected: started.version)
        var controller = try WorktimeController(url: url, sample: sample(220))
        try body(repo, &controller)
    }

    @Test func `preview does not save and confirmation fences stale proposals`() throws {
        try withController { repo, controller in
            let before = try repo.load(now: 221)
            let day = try #require(before.catalog.days.last)
            let reminders = try controller.reminderState(sample: sample(221))
            let proposal = try controller.previewClockOutCorrection(
                expectedDay: day, oldEnd: 200, newEnd: 180, sample: sample(221)
            )
            #expect(proposal.before.snapshot.bounds.lower == 100)
            #expect(proposal.after.snapshot.bounds.lower == 80)
            #expect(try repo.load(now: 221).version == before.version)
            #expect(try controller.reminderState(sample: sample(221)) == reminders)
            let result = try controller.commitClockOutCorrection(proposal, sample: sample(222))
            #expect(result?.snapshot.bounds.lower == 80)
            let saved = try repo.load(now: 222)
            #expect(saved.catalog.reviewAudit.last?.origin == .recordedClockOut)
            #expect(!controller.isCurrent(proposal))
            #expect(throws: ClockOutInteractionError.staleProposal) {
                try controller.commitClockOutCorrection(proposal, sample: sample(223))
            }
            #expect(try repo.load(now: 223).catalog == saved.catalog)
        }
    }

    @Test func `historical correction preserves active day and reminders`() throws {
        try withController { repo, controller in
            let ended = try #require(repo.load(now: 220).catalog.days.last)
            let activeID = UUID()
            _ = try controller.perform(.clockIn(id: activeID, profile: WorkdayProfile()), sample: sample(221))
            let page = try controller.recentHistory(now: 222)
            let context = try controller.historicalReviewContext(dayID: ended.id, history: page, sample: sample(222))
            let before = try repo.load(now: 222)
            let reminders = try controller.reminderState(sample: sample(222))
            let proposal = try controller.previewClockOutCorrection(
                expectedDay: context.glance.day, oldEnd: 200, newEnd: 210,
                historical: context, sample: sample(222)
            )
            #expect(try repo.load(now: 222).version == before.version)
            let result = try controller.commitClockOutCorrection(proposal, sample: sample(223))
            let saved = try repo.load(now: 223)
            #expect(saved.catalog.activeID == activeID)
            #expect(result?.day == before.catalog.days.last)
            #expect(saved.catalog.days.last == before.catalog.days.last)
            #expect(saved.catalog.observations[activeID] == before.catalog.observations[activeID])
            #expect(try controller.reminderState(sample: sample(223))?.desired == reminders?.desired)
            #expect(!controller.isCurrent(page))
        }
    }

    @Test func `unobserved gap rejects confirmation without writing and refresh invalidates it`() throws {
        try withController { repo, controller in
            let ended = try #require(repo.load(now: 220).catalog.days.last)
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(221))
            let page = try controller.recentHistory(now: 222)
            let context = try controller.historicalReviewContext(dayID: ended.id, history: page, sample: sample(222))
            let proposal = try controller.previewClockOutCorrection(
                expectedDay: context.glance.day, oldEnd: 200, newEnd: 210,
                historical: context, sample: sample(222)
            )
            let before = try repo.load(now: 222)
            #expect(throws: ClockOutInteractionError.staleProposal) {
                try controller.commitClockOutCorrection(proposal, sample: sample(240))
            }
            #expect(try repo.load(now: 240).version == before.version)
            _ = try controller.refresh(sample: sample(240))
            #expect(!controller.isCurrent(proposal))
            #expect(throws: ClockOutInteractionError.staleProposal) {
                try controller.commitClockOutCorrection(proposal, sample: sample(241))
            }
        }
    }
}
