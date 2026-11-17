import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct WorktimeControllerTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `normal observations keep verified work and forecast distinct`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let start = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            #expect(start?.forecast.goal == .projected(earliestGoalAt: 25300, estimatedDepartureAt: 28900))
            let current = try #require(controller.refresh(sample: sample(110)))
            #expect(current.snapshot.bounds.lower == 10)
            #expect(current.snapshot.bounds.upper == 10)
        }
    }

    @Test func `polling gap is recorded before clock out`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try controller.refresh(sample: sample(110))
            let ended = try #require(controller.perform(.clockOut(confirmBreak: false), sample: sample(140)))
            #expect(ended.snapshot.bounds.lower == 10)
            #expect(ended.snapshot.bounds.upper == 40)
            #expect(ended.forecast.goal == .ended)
            let later = try #require(controller.refresh(sample: sample(150)))
            #expect(later.snapshot == ended.snapshot)
        }
    }

    @Test func `reopen marks open work unverified instead of asserting attendance`() throws {
        try withDatabase { url in
            var first = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try first.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            var reopened = try WorktimeController(url: url, sample: sample(200))
            let current = try #require(reopened.refresh(sample: sample(210)))
            #expect(current.snapshot.bounds.lower == 10)
            #expect(current.snapshot.bounds.upper == 110)
            #expect(current.forecast.goal == .uncertain)
        }
    }

    @Test func `backward and divergent clocks are rejected`() throws {
        var monitor = try ClockObservation(initial: sample(100))
        #expect(throws: ApplicationClockError.unreliableClock) {
            try monitor.advance(to: sample(99))
        }
        let shifted = try ClockSample(wall: 200, uptime: 101)
        #expect(throws: ApplicationClockError.unreliableClock) {
            try monitor.advance(to: shifted)
        }
        #expect(try monitor.advance(to: sample(101)) == nil)
    }

    @Test func `break interval does not count as unverified work`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try controller.perform(.startBreak, sample: sample(110))
            let current = try #require(controller.refresh(sample: sample(200)))
            #expect(current.snapshot.bounds.lower == 10)
            #expect(current.snapshot.bounds.upper == 10)
            #expect(current.snapshot.recordedRest == 90)
            #expect(current.forecast.goal == .onBreak)
        }
    }

    @Test func `review preview does not persist and accepted rest survives reloading`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try controller.refresh(sample: sample(110))
            let gap = ObservationGap(start: 110, end: 140)
            let current = try #require(controller.refresh(sample: sample(140)))
            #expect(current.reviewableGaps == [gap])
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 141)
            let proposal = try controller.previewReview(selection: gap, classification: .rest, sample: sample(141))
            #expect(proposal.before.snapshot.bounds.lower == 11)
            #expect(proposal.before.snapshot.bounds.upper == 41)
            #expect(proposal.after.snapshot.bounds.lower == 11)
            #expect(proposal.after.snapshot.bounds.upper == 11)
            #expect(proposal.after.snapshot.recordedRest == 30)
            #expect(try repository.load(now: 141).version == before.version)
            #expect(controller.isCurrent(proposal))
            let accepted = try #require(controller.commitReview(proposal, sample: sample(142)))
            #expect(accepted.snapshot.bounds.lower == 12)
            #expect(accepted.reviewableGaps.isEmpty)
            #expect(!controller.isCurrent(proposal))
            let ended = try #require(controller.perform(.clockOut(confirmBreak: false), sample: sample(150)))
            var reopened = try WorktimeController(url: url, sample: sample(160))
            #expect(try reopened.refresh(sample: sample(160))?.snapshot == ended.snapshot)
            #expect(try repository.load(now: 160).catalog.reviewAudit.count == 1)
        }
    }

    @Test func `work and gap classifications have distinct effects`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let current = try #require(controller.refresh(sample: sample(140)))
            let gap = try #require(current.reviewableGaps.first)
            let work = try controller.previewReview(selection: gap, classification: .work, sample: sample(141))
            let nonwork = try controller.previewReview(selection: gap, classification: .gap, sample: sample(141))
            #expect(work.after.snapshot.bounds.lower == 41)
            #expect(nonwork.after.snapshot.bounds.upper == 1)
            #expect(nonwork.after.snapshot.recordedRest == 0)
            #expect(nonwork.after.snapshot.remainingRest == 3600)
            let saved = try #require(controller.commitReview(nonwork, sample: sample(142)))
            #expect(saved.snapshot.bounds.lower == 2)
            #expect(saved.snapshot.bounds.upper == 2)
            #expect(!controller.isCurrent(work))
        }
    }

    @Test func `gap during review invalidates proposal without committing it`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let current = try #require(controller.refresh(sample: sample(140)))
            let gap = try #require(current.reviewableGaps.first)
            let proposal = try controller.previewReview(selection: gap, classification: .work, sample: sample(141))
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.commitReview(proposal, sample: sample(170))
            }
            #expect(!controller.isCurrent(proposal))
            let repository = try CatalogRepository(url: url)
            #expect(try repository.load(now: 170).catalog.reviewAudit.isEmpty)
            let next = try #require(controller.refresh(sample: sample(170)))
            #expect(next.snapshot.bounds.upper == 70)
            #expect(next.snapshot.bounds.lower == 1)
        }
    }

    @Test func `ended day review changes evidence without advancing elapsed time`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let ended = try #require(controller.perform(.clockOut(confirmBreak: false), sample: sample(140)))
            let gap = try #require(ended.reviewableGaps.first)
            let proposal = try controller.previewReview(selection: gap, classification: .work, sample: sample(200))
            let accepted = try #require(controller.commitReview(proposal, sample: sample(201)))
            #expect(accepted.snapshot.bounds.lower == 40)
            #expect(accepted.snapshot.bounds.upper == 40)
            #expect(accepted.forecast.goal == .ended)
            #expect(try controller.refresh(sample: sample(300))?.snapshot == accepted.snapshot)
        }
    }
}
