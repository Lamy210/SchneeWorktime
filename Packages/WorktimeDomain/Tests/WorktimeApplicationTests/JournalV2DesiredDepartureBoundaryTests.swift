import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2DesiredDepartureBoundaryTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func fixture(_ body: (URL, JournalV2WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let controller = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        try body(url, controller)
    }

    @Test func `committed departure intention produces reminders without clocking out`() throws {
        try fixture { url, initial in
            var controller = initial
            let profile = try WorkdayProfile(target: 1, expectedRest: 0)
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(100))
            let plan = try controller.previewDesiredDeparture(at: 1100, sample: sample(101))
            let committed = try controller.commitDesiredDeparture(
                plan, warningAcknowledged: false, sample: sample(102)
            )
            #expect(committed?.forecast.goal == .reached)
            let reminder = try controller.reminderState(sample: sample(103))
            #expect(reminder?.desired.map(\.trigger) == [200])
            let catalog = try JournalV2Repository(url: url).load(now: 103).catalog
            let day = try #require(catalog.days.last)
            #expect(day.state == .working)
            #expect(catalog.desiredDepartures[day.id] == 1100)
        }
    }

    @Test func `departure changes while on break never fabricate a working checkpoint`() throws {
        try fixture { url, initial in
            var controller = initial
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let onBreak = try controller.perform(.startBreak, sample: sample(110))
            #expect(controller.checkpoint == nil)
            let plan = try controller.previewDesiredDeparture(at: 200, sample: sample(111))
            _ = try controller.commitDesiredDeparture(
                plan, warningAcknowledged: true, sample: sample(112)
            )
            #expect(controller.checkpoint == nil)
            let current = try controller.refresh(sample: sample(113))
            let day = try #require(current)
            #expect(day.desiredDepartureAt == 200)
            _ = try controller.clearDesiredDeparture(expectedDay: day.day, sample: sample(114))
            #expect(controller.checkpoint == nil)
            #expect(try JournalV2Repository(url: url).load(now: 115).checkpoint == nil)
            #expect(onBreak?.day.id == day.day.id)
        }
    }

    @Test func `checkpoint-only competitor invalidates a confirmed departure plan`() throws {
        try fixture { url, initial in
            var controller = initial
            let start = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let day = try #require(start)
            let plan = try controller.previewDesiredDeparture(at: 200, sample: sample(101))
            let repository = try JournalV2Repository(url: url)
            let source = try repository.load(now: 101)
            let changed = try repository.saveObservationCheckpoint(
                dayID: day.day.id, observedAt: 102, now: 102, matching: source
            )
            #expect(changed.version == source.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try controller.commitDesiredDeparture(
                    plan, warningAcknowledged: true, sample: sample(103)
                )
            }
            let saved = try repository.load(now: 103)
            #expect(saved.checkpoint == changed.checkpoint)
            #expect(saved.version == changed.version)
            #expect(saved.catalog.desiredDepartures.isEmpty)
        }
    }

    @Test func `different day or missing observation invalidates intent without mutation`() throws {
        try fixture { url, initial in
            var controller = initial
            let first = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let day = try #require(first)
            let plan = try controller.previewDesiredDeparture(at: 200, sample: sample(101))
            _ = try controller.perform(.startBreak, sample: sample(102))
            let before = try JournalV2Repository(url: url).load(now: 102)
            #expect(throws: DesiredDepartureSaveError.staleProposal) {
                try controller.commitDesiredDeparture(
                    plan, warningAcknowledged: true, sample: sample(103)
                )
            }
            #expect(throws: DesiredDepartureSaveError.staleProposal) {
                try controller.clearDesiredDeparture(expectedDay: day.day, sample: sample(103))
            }
            let after = try JournalV2Repository(url: url).load(now: 103)
            #expect(after.version == before.version)
            #expect(after.catalog == before.catalog)
            let later = try controller.previewDesiredDeparture(at: 300, sample: sample(103))
            #expect(throws: DesiredDepartureSaveError.staleProposal) {
                try controller.commitDesiredDeparture(
                    later, warningAcknowledged: true, sample: sample(140)
                )
            }
            #expect(try JournalV2Repository(url: url).load(now: 140).version == before.version)
        }
    }
}
