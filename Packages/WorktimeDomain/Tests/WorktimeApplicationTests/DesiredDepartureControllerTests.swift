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
}
