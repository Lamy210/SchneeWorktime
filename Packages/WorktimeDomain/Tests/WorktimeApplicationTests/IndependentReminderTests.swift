import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain

struct IndependentReminderTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `independent categories require opt in and survive ineligible desired departure`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let profile = try WorkdayProfile().capturingReference(
                at: 100, timeZoneID: "Etc/UTC", wallTime: ReferenceWallTime(hour: 2)
            )
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(100))
            let defaults = try controller.reminderState(sample: sample(101))
            #expect(defaults?.desired.map(\.kind) == [.departurePreparation(.fifteen)])
            let proposal = try controller.previewDesiredDeparture(at: 200, sample: sample(102))
            _ = try controller.commitDesiredDeparture(proposal, warningAcknowledged: true, sample: sample(103))
            let independent = try controller.reminderState(
                sample: sample(104), earliestLeads: [.fifteen], referenceEnabled: true
            )
            #expect(independent?.desired.map(\.kind) == [.earliestGoal(.fifteen), .referenceEnd])
            #expect(independent?.desired.map(\.trigger) == [24400, 7200])
            let disabled = try controller.reminderState(sample: sample(104))
            #expect(disabled?.desired.isEmpty == true)
            _ = try controller.perform(.startBreak, sample: sample(105))
            let resting = try controller.reminderState(
                sample: sample(106), earliestLeads: [.fifteen], referenceEnabled: true
            )
            #expect(resting?.desired.map(\.kind) == [.referenceEnd])
            _ = try controller.perform(.clockOut(confirmBreak: true), sample: sample(107))
            let ended = try controller.reminderState(
                sample: sample(108), earliestLeads: [.fifteen], referenceEnabled: true
            )
            #expect(ended?.desired.isEmpty == true)
        }
    }

    @Test func `disabled and before start references never schedule independent alerts`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let profile = try WorkdayProfile().capturingReference(
                at: 100, timeZoneID: "Etc/UTC", wallTime: ReferenceWallTime(hour: 0)
            )
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(100))
            let state = try controller.reminderState(
                sample: sample(101), departureLeads: [], referenceEnabled: true
            )
            #expect(state?.desired.isEmpty == true)
        }
    }
}
