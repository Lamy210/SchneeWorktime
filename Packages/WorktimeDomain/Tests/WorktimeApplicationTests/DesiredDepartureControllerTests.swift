import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct DesiredDepartureControllerTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `preview and failed warning confirmation leave the saved snapshot untouched`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            let proposal = try controller.previewDesiredDeparture(at: 200, sample: sample(101))
            #expect(proposal.assessment.status == .infeasible)
            #expect(try store.load() == before)
            #expect(throws: DesiredDepartureSaveError.confirmationRequired) {
                try controller.commitDesiredDeparture(proposal, warningAcknowledged: false, sample: sample(102))
            }
            #expect(try store.load() == before)
            let saved = try controller.commitDesiredDeparture(
                proposal, warningAcknowledged: true, sample: sample(103)
            )
            #expect(saved?.desiredDepartureAt == 200)
            #expect(saved?.day.state == .working)
            #expect(saved?.day.intervals.count == 1)
        }
    }

    @Test func `another command invalidates a displayed proposal without saving intention`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let proposal = try controller.previewDesiredDeparture(at: 28800, sample: sample(101))
            _ = try controller.perform(.startBreak, sample: sample(102))
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            #expect(throws: DesiredDepartureSaveError.staleProposal) {
                try controller.commitDesiredDeparture(proposal, warningAcknowledged: true, sample: sample(103))
            }
            #expect(try store.load() == before)
            let current = try controller.refresh(sample: sample(104))
            #expect(current?.desiredDepartureAt == nil)
        }
    }

    @Test func `rest change requalifies desired reminder and explicit clear restores automatic estimate`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            let proposal = try controller.previewDesiredDeparture(at: 2800, sample: sample(101))
            let saved = try controller.commitDesiredDeparture(
                proposal, warningAcknowledged: true, sample: sample(102)
            )
            let active = try #require(saved)
            let ineligible = try controller.reminderState(sample: sample(103))
            #expect(ineligible?.desired.isEmpty == true)
            let changed = try controller.setFutureRest(minutes: 30, expectedDay: active.day, sample: sample(104))
            let current = try #require(changed)
            #expect(current.desiredDepartureAt == 2800)
            let requalified = try controller.reminderState(sample: sample(105))
            #expect(requalified?.desired.map(\.trigger) == [1900])
            let multiple = try controller.reminderState(
                sample: sample(105), departureLeads: [.five, .fifteen, .thirty]
            )
            #expect(multiple?.desired.map(\.trigger) == [2500, 1900, 1000])
            let disabled = try controller.reminderState(sample: sample(105), departureLeads: [])
            #expect(disabled?.desired.isEmpty == true)
            let cleared = try controller.clearDesiredDeparture(expectedDay: current.day, sample: sample(106))
            #expect(cleared?.desiredDepartureAt == nil)
            let automatic = try controller.reminderState(sample: sample(107))
            #expect(automatic?.desired.map(\.trigger) == [26200])
        }
    }

    @Test func `desired reminder remains valid after reaching target and expires without auto clock out`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let profile = try WorkdayProfile(target: 1, expectedRest: 0)
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(100))
            let proposal = try controller.previewDesiredDeparture(at: 1100, sample: sample(101))
            let saved = try controller.commitDesiredDeparture(
                proposal, warningAcknowledged: false, sample: sample(102)
            )
            #expect(saved?.forecast.goal == .reached)
            let reminder = try controller.reminderState(sample: sample(103))
            #expect(reminder?.desired.map(\.trigger) == [200])
            let repo = try CatalogRepository(url: url)
            let expired = try repo.load(now: 1101)
            let glance = try WorktimeGlance(catalog: expired.catalog, now: 1101)
            #expect(glance.day.state == .working)
            #expect(glance.desiredDepartureAt == 1100)
            #expect(try glance.departureReminderBasis() == .explicit(nil))
        }
    }
}
