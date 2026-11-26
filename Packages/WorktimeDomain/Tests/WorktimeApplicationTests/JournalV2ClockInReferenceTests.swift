import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ClockInReferenceTests {
    private func sample(_ wall: Int64) throws -> ClockSample {
        try ClockSample(wall: wall, uptime: Double(wall))
    }

    private func fixture(_ run: (URL, JournalV2WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try run(url, JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100)))
    }

    @Test func `clock in reference uses actual commit sample and remains independent of work target`() throws {
        try fixture { url, initial in
            var controller = initial
            let expected = controller.workActionContext
            let profile = try WorkdayProfile()
            let settings = try JournalV2ClockInSettings(
                profile: profile, timeZoneID: "Etc/UTC", wallTime: ReferenceWallTime(hour: 2)
            )
            let result = try controller.performConfirmedClockIn(
                id: UUID(), displayed: settings, current: settings, matching: expected, sample: sample(105)
            )
            let reference = try #require(result?.day.profile.reference)
            #expect(reference.startedAt == 105)
            #expect(reference.referenceAt == 7200)
            #expect(result?.day.profile.target == profile.target)
            #expect(try JournalV2Repository(url: url).load(now: 105).catalog.days.last?.profile.reference == reference)
            #expect(controller.checkpoint?.observedAt == 105)
            let optedOut = try controller.reminderState(sample: sample(106), departureLeads: [])
            #expect(optedOut?.desired.isEmpty == true)
            let optedIn = try controller.reminderState(
                sample: sample(106), departureLeads: [], referenceEnabled: true
            )
            #expect(optedIn?.desired.map(\.kind) == [.referenceEnd])
            #expect(optedIn?.desired.map(\.trigger) == [7200])
            _ = try controller.performConfirmed(
                .clockOut(confirmBreak: false), matching: controller.workActionContext, sample: sample(107)
            )
            let ended = try controller.reminderState(
                sample: sample(108), departureLeads: [], referenceEnabled: true
            )
            #expect(ended?.desired.isEmpty == true)
        }
    }

    @Test func `changed reference settings and timezone refuse clock in without modifying storage`() throws {
        try fixture { url, initial in
            var controller = initial
            let profile = try WorkdayProfile()
            let expected = controller.workActionContext
            let time = try ReferenceWallTime(hour: 2)
            let settings = JournalV2ClockInSettings(profile: profile, timeZoneID: "Etc/UTC", wallTime: time)
            let changes = [
                JournalV2ClockInSettings(profile: profile, timeZoneID: "Asia/Tokyo", wallTime: time),
                JournalV2ClockInSettings(profile: profile, timeZoneID: "Etc/UTC", wallTime: nil)
            ]
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 100)
            for changed in changes {
                #expect(throws: JournalV2WorkActionError.staleContext) {
                    try controller.performConfirmedClockIn(
                        id: UUID(), displayed: settings, current: changed, matching: expected, sample: sample(101)
                    )
                }
            }
            let after = try repository.load(now: 101)
            #expect(after.version == before.version)
            #expect(after.catalog == before.catalog)
            #expect(after.checkpoint == before.checkpoint)
        }
    }

    @Test func `invalid reference is rejected before any attendance write`() throws {
        try fixture { url, initial in
            var controller = initial
            let settings = try JournalV2ClockInSettings(
                profile: WorkdayProfile(), timeZoneID: "invalid/timezone", wallTime: ReferenceWallTime()
            )
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 100)
            #expect(throws: JournalV2ClockInSettingsError.invalidReference) {
                try controller.performConfirmedClockIn(
                    id: UUID(), displayed: settings, current: settings,
                    matching: controller.workActionContext, sample: sample(101)
                )
            }
            let after = try repository.load(now: 101)
            #expect(after.version == before.version)
            #expect(after.catalog == before.catalog)
            #expect(after.checkpoint == before.checkpoint)
        }
    }

    @Test func `disabled reference captures timezone without creating a reference notification`() throws {
        try fixture { url, initial in
            var controller = initial
            let settings = try JournalV2ClockInSettings(
                profile: WorkdayProfile(), timeZoneID: "Etc/UTC", wallTime: nil
            )
            _ = try controller.performConfirmedClockIn(
                id: UUID(), displayed: settings, current: settings,
                matching: controller.workActionContext, sample: sample(101)
            )
            let saved = try JournalV2Repository(url: url).load(now: 101)
            #expect(saved.catalog.days.last?.profile.reference?.resolution == .disabled)
            #expect(saved.catalog.days.last?.profile.reference?.timeZoneID == "Etc/UTC")
            let state = try controller.reminderState(
                sample: sample(102), departureLeads: [], referenceEnabled: true
            )
            #expect(state?.desired.isEmpty == true)
        }
    }
}
