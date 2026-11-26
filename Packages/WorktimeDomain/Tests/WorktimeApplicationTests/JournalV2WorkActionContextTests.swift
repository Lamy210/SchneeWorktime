import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2WorkActionContextTests {
    private func sample(_ instant: Int64) throws -> ClockSample {
        try ClockSample(wall: instant, uptime: Double(instant))
    }

    private func fixture(_ run: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try run(root.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `exclusive new install refuses reuse of an existing schema two database`() throws {
        try fixture { url in
            let first = try JournalV2WorktimeController(
                url: url, createIfMissing: true, requireNew: true, sample: sample(100)
            )
            let before = try Data(contentsOf: url)
            #expect(first.version.revision == 0)
            #expect(throws: SnapshotStoreError.invalidSnapshot) {
                try JournalV2WorktimeController(
                    url: url, createIfMissing: true, requireNew: true, sample: sample(101)
                )
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func `exclusive new install refuses a legacy database without altering it`() throws {
        try fixture { url in
            _ = try SnapshotStore(url: url, createIfMissing: true)
            let before = try Data(contentsOf: url)
            #expect(throws: SnapshotStoreError.invalidSnapshot) {
                try JournalV2WorktimeController(
                    url: url, createIfMissing: true, requireNew: true, sample: sample(100)
                )
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func `confirmed schema two clock in break and clock out persist in one journal`() throws {
        try fixture { url in
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, requireNew: true, sample: sample(100)
            )
            let empty = current.workActionContext
            #expect(empty.canOpenWorkday)
            let dayID = UUID()
            let started = try current.performConfirmed(
                .clockIn(id: dayID, profile: WorkdayProfile()),
                matching: empty, sample: sample(100)
            )
            #expect(started?.day.state == .working)
            #expect(current.checkpoint?.observedAt == 100)
            #expect(throws: JournalV2WorkActionError.staleContext) {
                try current.performConfirmed(.startBreak, matching: empty, sample: sample(101))
            }
            let breakStart = try current.performConfirmed(
                .startBreak, matching: current.workActionContext, sample: sample(110)
            )
            #expect(breakStart?.day.state == .onBreak)
            #expect(current.checkpoint == nil)
            let breakEnd = try current.performConfirmed(
                .endBreak, matching: current.workActionContext, sample: sample(120)
            )
            #expect(breakEnd?.day.state == .working)
            #expect(current.checkpoint?.observedAt == 120)
            let ended = try current.performConfirmed(
                .clockOut(confirmBreak: false),
                matching: current.workActionContext, sample: sample(130)
            )
            #expect(ended?.day.state == .ended)
            #expect(current.checkpoint == nil)
            let saved = try JournalV2Repository(url: url).load(now: 130)
            #expect(saved.version == current.version)
            #expect(saved.version.revision == 4)
            #expect(saved.catalog.days.last?.id == dayID)
            #expect(saved.catalog.days.last?.intervals.count == 3)
        }
    }

    @Test func `clock out while on break requires explicit confirmation`() throws {
        try fixture { url in
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, requireNew: true, sample: sample(100)
            )
            _ = try current.performConfirmed(
                .clockIn(id: UUID(), profile: WorkdayProfile()),
                matching: current.workActionContext, sample: sample(100)
            )
            _ = try current.performConfirmed(
                .startBreak, matching: current.workActionContext, sample: sample(110)
            )
            let before = try JournalV2Repository(url: url).load(now: 111)
            #expect(throws: JournalV2WorkActionError.invalidTransition) {
                try current.performConfirmed(
                    .clockOut(confirmBreak: false),
                    matching: current.workActionContext, sample: sample(111)
                )
            }
            let unchanged = try JournalV2Repository(url: url).load(now: 111)
            #expect(unchanged.version == before.version)
            #expect(unchanged.catalog == before.catalog)
            let ended = try current.performConfirmed(
                .clockOut(confirmBreak: true),
                matching: current.workActionContext, sample: sample(112)
            )
            #expect(ended?.day.state == .ended)
            #expect(try JournalV2Repository(url: url).load(now: 112).checkpoint == nil)
        }
    }

    @Test func `checkpoint-only competitor invalidates a previously confirmed action`() throws {
        try fixture { url in
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, requireNew: true, sample: sample(100)
            )
            let id = UUID()
            _ = try current.performConfirmed(
                .clockIn(id: id, profile: WorkdayProfile()),
                matching: current.workActionContext, sample: sample(100)
            )
            let displayed = current.workActionContext
            let repository = try JournalV2Repository(url: url)
            let before = try repository.load(now: 101)
            let other = try repository.saveObservationCheckpoint(
                dayID: id, observedAt: 105, now: 105, matching: before
            )
            #expect(other.version == before.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try current.performConfirmed(.startBreak, matching: displayed, sample: sample(106))
            }
            let disk = try repository.load(now: 106)
            #expect(disk.checkpoint == other.checkpoint)
            #expect(disk.catalog.days.last?.state == .working)
            #expect(disk.version == other.version)
        }
    }

    @Test func `a refreshed checkpoint invalidates old UI confirmation`() throws {
        try fixture { url in
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, requireNew: true, sample: sample(100)
            )
            _ = try current.performConfirmed(
                .clockIn(id: UUID(), profile: WorkdayProfile()),
                matching: current.workActionContext, sample: sample(100)
            )
            let displayed = current.workActionContext
            _ = try current.refresh(sample: sample(110))
            #expect(current.checkpoint?.observedAt == 110)
            #expect(throws: JournalV2WorkActionError.staleContext) {
                try current.performConfirmed(.startBreak, matching: displayed, sample: sample(111))
            }
            #expect(try JournalV2Repository(url: url).load(now: 111).catalog.days.last?.state == .working)
        }
    }

    @Test func `invalid initial transition is rejected without creating a journal event`() throws {
        try fixture { url in
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, requireNew: true, sample: sample(100)
            )
            let before = try JournalV2Repository(url: url).load(now: 100)
            #expect(throws: JournalV2WorkActionError.invalidTransition) {
                try current.performConfirmed(
                    .clockOut(confirmBreak: false),
                    matching: current.workActionContext, sample: sample(100)
                )
            }
            let after = try JournalV2Repository(url: url).load(now: 100)
            #expect(after.version == before.version)
            #expect(after.catalog == before.catalog)
            #expect(after.checkpoint == before.checkpoint)
        }
    }
}
