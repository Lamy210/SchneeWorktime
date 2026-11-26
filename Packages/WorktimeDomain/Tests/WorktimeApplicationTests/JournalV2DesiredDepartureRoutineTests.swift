import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2DesiredDepartureRoutineTests {
    private func sample(_ at: Int64) throws -> ClockSample {
        try ClockSample(wall: at, uptime: Double(at))
    }

    private func fixture(_ run: (URL, JournalV2WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        var controller = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        _ = try controller.perform(
            .clockIn(id: UUID(), profile: WorkdayProfile(target: 3600, expectedRest: 0)), sample: sample(100)
        )
        try run(url, controller)
    }

    @Test func `unchanged forecast can be saved after routine local checkpoint updates`() throws {
        try fixture { url, initial in
            var current = initial
            let displayed = current.workActionContext
            let plan = try current.previewDesiredDeparture(at: 4000, sample: sample(100))
            for time in stride(from: Int64(110), through: 160, by: 10) {
                _ = try current.refresh(sample: sample(time))
            }
            let result = try current.commitConfirmedDesiredDeparture(
                plan, matching: displayed, warningAcknowledged: false, sample: sample(161)
            )
            #expect(result?.desiredDepartureAt == 4000)
            let saved = try JournalV2Repository(url: url).load(now: 161)
            #expect(saved.version.revision == displayed.version.revision + 1)
            #expect(saved.checkpoint?.observedAt == 161)
        }
    }

    @Test func `clear survives routine observation but a changed intention requires a new confirmation`() throws {
        try fixture { url, initial in
            var current = initial
            let plan = try current.previewDesiredDeparture(at: 4000, sample: sample(100))
            _ = try current.commitDesiredDeparture(plan, warningAcknowledged: false, sample: sample(101))
            let displayed = current.workActionContext
            _ = try current.refresh(sample: sample(111))
            let result = try current.clearConfirmedDesiredDeparture(matching: displayed, sample: sample(112))
            #expect(result?.desiredDepartureAt == nil)
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 112)
            #expect(before.version.revision == displayed.version.revision + 1)
            #expect(throws: DesiredDepartureSaveError.staleProposal) {
                try current.clearConfirmedDesiredDeparture(matching: displayed, sample: sample(113))
            }
            #expect(try repository.load(now: 113).version == before.version)
        }
    }

    @Test func `external checkpoint is not accepted by routine confirmation`() throws {
        try fixture { url, initial in
            var current = initial
            let displayed = current.workActionContext
            let proposal = try current.previewDesiredDeparture(at: 4000, sample: sample(100))
            _ = try current.refresh(sample: sample(110))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 110)
            let day = try #require(before.catalog.days.last)
            let external = try repository.saveObservationCheckpoint(
                dayID: day.id, observedAt: 111, now: 111, matching: before
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try current.commitConfirmedDesiredDeparture(
                    proposal, matching: displayed, warningAcknowledged: false, sample: sample(112)
                )
            }
            let after = try repository.load(now: 112)
            #expect(after.version == external.version)
            #expect(after.catalog == external.catalog)
            #expect(after.checkpoint == external.checkpoint)
        }
    }

    @Test func `expired candidate and changed journal are rejected without writing intention`() throws {
        try fixture { url, initial in
            var current = initial
            let displayed = current.workActionContext
            let proposal = try current.previewDesiredDeparture(at: 110, sample: sample(100))
            _ = try current.refresh(sample: sample(110))
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 111)
            #expect(throws: DesiredDepartureSaveError.invalidCandidate) {
                try current.commitConfirmedDesiredDeparture(
                    proposal, matching: displayed, warningAcknowledged: true, sample: sample(111)
                )
            }
            #expect(try repository.load(now: 111).version == before.version)
            #expect(try repository.load(now: 111).catalog == before.catalog)
            _ = try current.perform(.startBreak, sample: sample(112))
            #expect(throws: DesiredDepartureSaveError.staleProposal) {
                try current.commitConfirmedDesiredDeparture(
                    proposal, matching: displayed, warningAcknowledged: true, sample: sample(113)
                )
            }
            #expect(try repository.load(now: 113).catalog.desiredDepartures.isEmpty)
        }
    }
}
