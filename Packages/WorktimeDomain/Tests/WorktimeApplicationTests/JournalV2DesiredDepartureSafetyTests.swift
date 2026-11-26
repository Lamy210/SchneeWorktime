import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2DesiredDepartureSafetyTests {
    private func sample(_ wall: Int64) throws -> ClockSample {
        try ClockSample(wall: wall, uptime: Double(wall))
    }

    private func fixture(_ run: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(directory.appendingPathComponent("worktime.sqlite"))
    }

    private func started(_ url: URL, profile: WorkdayProfile = WorkdayProfile()) throws
        -> (JournalV2WorktimeController, UUID) {
        var controller = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        let dayID = UUID()
        _ = try controller.perform(
            .clockIn(id: dayID, profile: profile), sample: sample(100)
        )
        return (controller, dayID)
    }

    @Test func `feasible explicit intent changes only its own reminder target and can be cleared`() throws {
        try fixture { url in
            let (initial, dayID) = try started(
                url, profile: WorkdayProfile(target: 3600, expectedRest: 0)
            )
            var controller = initial
            let proposal = try controller.previewDesiredDeparture(at: 4000, sample: sample(101))
            #expect(proposal.assessment.status == .feasible)
            let repo = try JournalV2Repository(url: url)
            let before = try repo.load(now: 101)
            #expect(before.catalog.desiredDepartures.isEmpty)
            #expect(try repo.load(now: 101).version == before.version)
            let changed = try controller.commitDesiredDeparture(
                proposal, warningAcknowledged: false, sample: sample(102)
            )
            #expect(changed?.desiredDepartureAt == 4000)
            #expect(changed?.day.id == dayID)
            let plan = try controller.reminderState(sample: sample(103))
            #expect(plan?.desired.count == 1)
            #expect(plan?.desired.first?.trigger == 3100)

            let cleared = try controller.clearDesiredDeparture(
                expectedDay: try #require(changed?.day), sample: sample(104)
            )
            #expect(cleared?.desiredDepartureAt == nil)
            let automatic = try controller.reminderState(sample: sample(105))
            #expect(automatic?.desired.first?.trigger == 2800)
            #expect(try repo.load(now: 105).catalog.desiredDepartures.isEmpty)
        }
    }

    @Test func `warning intent cannot be committed without explicit acknowledgement`() throws {
        try fixture { url in
            let (initial, _) = try started(url)
            var controller = initial
            let proposed = try controller.previewDesiredDeparture(at: 200, sample: sample(101))
            #expect(proposed.assessment.status == .infeasible)
            let repo = try JournalV2Repository(url: url)
            let old = try repo.load(now: 102)
            #expect(throws: DesiredDepartureSaveError.confirmationRequired) {
                try controller.commitDesiredDeparture(
                    proposed, warningAcknowledged: false, sample: sample(102)
                )
            }
            #expect(try repo.load(now: 102).version == old.version)
            _ = try controller.commitDesiredDeparture(
                proposed, warningAcknowledged: true, sample: sample(103)
            )
            #expect(try repo.load(now: 103).catalog.desiredDepartures.count == 1)
            #expect(try controller.reminderState(sample: sample(104))?.desired.isEmpty == true)
        }
    }

    @Test func `same revision checkpoint-only write rejects preview confirmation`() throws {
        try fixture { url in
            let (initial, id) = try started(url)
            var controller = initial
            let proposed = try controller.previewDesiredDeparture(at: 200, sample: sample(101))
            let repo = try JournalV2Repository(url: url)
            let original = try repo.load(now: 101)
            let concurrent = try repo.saveObservationCheckpoint(
                dayID: id, observedAt: 102, now: 102, matching: original
            )
            #expect(concurrent.version == original.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try controller.commitDesiredDeparture(
                    proposed, warningAcknowledged: true, sample: sample(103)
                )
            }
            let after = try repo.load(now: 103)
            #expect(after.version == concurrent.version)
            #expect(after.checkpoint == concurrent.checkpoint)
            #expect(after.catalog.desiredDepartures.isEmpty)
        }
    }

    @Test func `clock out after preview invalidates stale intent without writing`() throws {
        try fixture { url in
            let (initial, _) = try started(url)
            var controller = initial
            let proposed = try controller.previewDesiredDeparture(at: 200, sample: sample(101))
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(102))
            let repo = try JournalV2Repository(url: url)
            let ended = try repo.load(now: 102)
            #expect(throws: DesiredDepartureSaveError.staleProposal) {
                try controller.commitDesiredDeparture(
                    proposed, warningAcknowledged: true, sample: sample(103)
                )
            }
            let after = try repo.load(now: 103)
            #expect(after.version == ended.version)
            #expect(after.catalog.desiredDepartures.isEmpty)
            #expect(after.catalog.days.last?.state == .ended)
        }
    }

    @Test func `clear during a recorded break does not resume attendance or retain desired reminder`() throws {
        try fixture { url in
            let (initial, _) = try started(url)
            var controller = initial
            let proposed = try controller.previewDesiredDeparture(at: 200, sample: sample(101))
            _ = try controller.commitDesiredDeparture(
                proposed, warningAcknowledged: true, sample: sample(102)
            )
            let paused = try #require(controller.perform(.startBreak, sample: sample(103)))
            #expect(paused.day.state == .onBreak)
            let cleared = try controller.clearDesiredDeparture(expectedDay: paused.day, sample: sample(104))
            #expect(cleared?.day.state == .onBreak)
            #expect(cleared?.desiredDepartureAt == nil)
            let disk = try JournalV2Repository(url: url).load(now: 104)
            #expect(disk.catalog.days.last?.state == .onBreak)
            #expect(disk.checkpoint == nil)
        }
    }
}
