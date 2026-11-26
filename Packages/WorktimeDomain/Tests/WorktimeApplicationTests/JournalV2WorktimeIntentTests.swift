import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2WorktimeIntentTests {
    private func sample(_ at: Int64) throws -> ClockSample {
        try ClockSample(wall: at, uptime: Double(at))
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

    @Test func `backdated start is explicitly asserted and atomically checkpointed`() throws {
        try fixture { url, initial in
            var controller = initial
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 100)
            let proposal = try controller.previewRetrospectiveStart(
                at: 90, profile: WorkdayProfile(), sample: sample(100)
            )
            #expect(proposal.preview.snapshot.bounds.lower == 10)
            #expect(controller.isCurrent(proposal))
            let unchanged = try repository.load(now: 100)
            #expect(unchanged.version == before.version)
            #expect(unchanged.catalog == before.catalog)
            #expect(unchanged.checkpoint == before.checkpoint)
            let result = try controller.commitRetrospectiveStart(proposal, sample: sample(101))
            let saved = try #require(result)
            #expect(saved.snapshot.bounds.lower == 11)
            #expect(saved.snapshot.bounds.upper == 11)
            #expect(saved.day.intervals.first?.start == 90)
            let committed = try repository.load(now: 101)
            #expect(committed.version.revision == 1)
            #expect(committed.version == controller.version)
            #expect(committed.checkpoint?.observedAt == 101)
            #expect(committed.checkpoint?.dayID == saved.day.id)
        }
    }

    @Test func `confirmed retrospective start rejects changed settings and preserves the original journal`() throws {
        try fixture { url, initial in
            var controller = initial
            let profile = try WorkdayProfile()
            let changed = try WorkdayProfile(target: 3600, expectedRest: 0)
            let expected = controller.workActionContext
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 100)
            let proposal = try controller.previewConfirmedRetrospectiveStart(
                at: 90, profile: profile, matching: expected, sample: sample(100)
            )
            #expect(throws: RetrospectiveStartError.staleProposal) {
                try controller.commitConfirmedRetrospectiveStart(
                    proposal, profile: changed, matching: expected, sample: sample(101)
                )
            }
            let untouched = try repository.load(now: 101)
            #expect(untouched.version == before.version)
            #expect(untouched.catalog == before.catalog)
            #expect(untouched.checkpoint == before.checkpoint)
            let result = try controller.commitConfirmedRetrospectiveStart(
                proposal, profile: profile, matching: expected, sample: sample(102)
            )
            #expect(result?.day.profile == profile)
            #expect(result?.day.intervals.first?.start == 90)
            #expect(try repository.load(now: 102).checkpoint?.observedAt == 102)
            #expect(throws: RetrospectiveStartError.staleProposal) {
                try controller.commitConfirmedRetrospectiveStart(
                    proposal, profile: profile, matching: expected, sample: sample(103)
                )
            }
            #expect(try repository.load(now: 103).catalog.days.count == 1)
        }
    }

    @Test func `confirmed retrospective start rejects an obsolete idle context`() throws {
        try fixture { url, initial in
            var controller = initial
            let profile = try WorkdayProfile()
            let expected = controller.workActionContext
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(101))
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(110))
            #expect(throws: RetrospectiveStartError.staleProposal) {
                try controller.previewConfirmedRetrospectiveStart(
                    at: 111, profile: profile, matching: expected, sample: sample(112)
                )
            }
            let saved = try JournalV2Repository(url: url).load(now: 112)
            #expect(saved.catalog.days.count == 1)
            #expect(saved.catalog.activeID == nil)
        }
    }

    @Test func `backdated start refuses stale confirmation and overlapping start`() throws {
        try fixture { url, initial in
            var controller = initial
            let profile = try WorkdayProfile()
            let plan = try controller.previewRetrospectiveStart(
                at: 90, profile: profile, sample: sample(100)
            )
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: profile), sample: sample(101)
            )
            #expect(!controller.isCurrent(plan))
            #expect(throws: RetrospectiveStartError.staleProposal) {
                try controller.commitRetrospectiveStart(plan, sample: sample(102))
            }
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(110))
            #expect(throws: RetrospectiveStartError.invalidStart) {
                try controller.previewRetrospectiveStart(at: 105, profile: profile, sample: sample(120))
            }
            #expect(throws: RetrospectiveStartError.invalidStart) {
                try controller.previewRetrospectiveStart(at: 121, profile: profile, sample: sample(120))
            }
            #expect(try JournalV2Repository(url: url).load(now: 120).catalog.days.count == 1)
        }
    }

    @Test func `lost observations reject a stale retrospective confirmation without a write`() throws {
        try fixture { url, initial in
            var controller = initial
            let plan = try controller.previewRetrospectiveStart(
                at: 90, profile: WorkdayProfile(), sample: sample(100)
            )
            let before = try JournalV2Repository(url: url).load(now: 120)
            #expect(throws: RetrospectiveStartError.staleProposal) {
                try controller.commitRetrospectiveStart(plan, sample: sample(120))
            }
            let after = try JournalV2Repository(url: url).load(now: 120)
            #expect(after.version == before.version)
            #expect(after.catalog == before.catalog)
        }
    }

    @Test func `desired departure warning requires consent and event commits its checkpoint`() throws {
        try fixture { url, initial in
            var controller = initial
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 101)
            let plan = try controller.previewDesiredDeparture(at: 200, sample: sample(101))
            #expect(plan.assessment.status == .infeasible)
            #expect(controller.isCurrent(plan))
            #expect(try repository.load(now: 101).version == before.version)
            #expect(throws: DesiredDepartureSaveError.confirmationRequired) {
                try controller.commitDesiredDeparture(
                    plan, warningAcknowledged: false, sample: sample(102)
                )
            }
            let result = try controller.commitDesiredDeparture(
                plan, warningAcknowledged: true, sample: sample(103)
            )
            let saved = try #require(result)
            #expect(saved.desiredDepartureAt == 200)
            #expect(saved.day.state == .working)
            #expect(saved.day.intervals.count == 1)
            let committed = try repository.load(now: 103)
            #expect(committed.version.revision == before.version.revision + 1)
            #expect(committed.checkpoint?.observedAt == 103)
            #expect(committed.catalog.desiredDepartures[saved.day.id] == 200)
        }
    }

    @Test func `desired departure no-op and repeat clear do not append redundant events`() throws {
        try fixture { url, initial in
            var controller = initial
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100)
            )
            let plan = try controller.previewDesiredDeparture(at: 1100, sample: sample(101))
            let savedResult = try controller.commitDesiredDeparture(
                plan, warningAcknowledged: true, sample: sample(102)
            )
            let saved = try #require(savedResult)
            let revision = controller.version.revision
            let repeated = try controller.previewDesiredDeparture(at: 1100, sample: sample(103))
            _ = try controller.commitDesiredDeparture(
                repeated, warningAcknowledged: true, sample: sample(104)
            )
            #expect(controller.version.revision == revision)
            let clearedResult = try controller.clearDesiredDeparture(
                expectedDay: saved.day, sample: sample(105)
            )
            let cleared = try #require(clearedResult)
            #expect(cleared.desiredDepartureAt == nil)
            #expect(controller.version.revision == revision + 1)
            let again = try controller.clearDesiredDeparture(expectedDay: cleared.day, sample: sample(106))
            #expect(again?.desiredDepartureAt == nil)
            #expect(controller.version.revision == revision + 1)
            let disk = try JournalV2Repository(url: url).load(now: 106)
            #expect(disk.version == controller.version)
            #expect(disk.checkpoint?.observedAt == 105)
            #expect(disk.catalog.desiredDepartures.isEmpty)
        }
    }
}
