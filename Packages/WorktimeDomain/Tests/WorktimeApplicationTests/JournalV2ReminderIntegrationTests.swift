import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore
@testable import WorktimeApplication

@MainActor
private final class SchemaTwoReminderDeliveryFake: ReminderDelivery {
    var authorizationValue: ReminderAuthorization = .allowed
    var requests: [PendingReminder] = []
    var added: [ReminderRequest] = []
    var cancelled: [String] = []

    func authorization() async -> ReminderAuthorization { authorizationValue }
    func requestAuthorization() async throws -> Bool { authorizationValue == .allowed }
    func pending() async -> [PendingReminder] { requests }

    func cancel(ids: [String]) {
        cancelled.append(contentsOf: ids)
        requests.removeAll { ids.contains($0.id) }
    }

    func schedule(_ request: ReminderRequest) async throws {
        added.append(request)
        requests.removeAll { $0.id == request.id }
        requests.append(PendingReminder(
            id: request.id, trigger: request.trigger,
            revision: request.revision, payloadVersion: request.payloadVersion
        ))
    }
}

@MainActor
struct JournalV2ReminderIntegrationTests {
    private func sample(_ wall: Int64, uptime: Double? = nil) throws -> ClockSample {
        try ClockSample(wall: wall, uptime: uptime ?? Double(wall))
    }

    private func fixture(_ work: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await work(root.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `schema two reminders follow committed clock in break resume and clock out`() async throws {
        try await fixture { url in
            let delivery = SchemaTwoReminderDeliveryFake()
            let sync = ReminderSync(delivery: delivery)
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            let id = UUID()
            _ = try current.performConfirmed(
                .clockIn(id: id, profile: WorkdayProfile(target: 3600, expectedRest: 0)),
                matching: current.workActionContext, sample: sample(100)
            )
            let initial = try current.reminderState(
                sample: sample(105), departureLeads: [.fifteen]
            )
            #expect(initial?.dayID == id)
            #expect(initial?.desired.count == 1)
            let pending = try await sync.reconcile(latest: { initial }, now: { 105 })
            #expect(pending == .settled)
            #expect(delivery.added.count == 1)
            #expect(delivery.requests.count == 1)

            _ = try current.performConfirmed(
                .startBreak, matching: current.workActionContext, sample: sample(110)
            )
            let paused = try current.reminderState(sample: sample(111))
            #expect(paused?.desired.isEmpty == true)
            let removed = try await sync.reconcile(latest: { paused }, now: { 111 })
            #expect(removed == .settled)
            #expect(delivery.requests.isEmpty)
            #expect(delivery.cancelled.count == 1)

            _ = try current.performConfirmed(
                .endBreak, matching: current.workActionContext, sample: sample(120)
            )
            let resumed = try current.reminderState(sample: sample(121))
            #expect(resumed?.desired.count == 1)
            let rescheduled = try await sync.reconcile(latest: { resumed }, now: { 121 })
            #expect(rescheduled == .settled)
            #expect(delivery.requests.count == 1)

            _ = try current.performConfirmed(
                .clockOut(confirmBreak: false),
                matching: current.workActionContext, sample: sample(130)
            )
            let ended = try current.reminderState(sample: sample(131))
            #expect(ended?.desired.isEmpty == true)
            let settled = try await sync.reconcile(latest: { ended }, now: { 131 })
            #expect(settled == .settled)
            #expect(delivery.requests.isEmpty)
            #expect(delivery.cancelled.count == 2)
        }
    }

    @Test func `untrusted clock clears schema two owned notifications but preserves foreign IDs`() async throws {
        try await fixture { url in
            let delivery = SchemaTwoReminderDeliveryFake()
            let sync = ReminderSync(delivery: delivery)
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            _ = try current.performConfirmed(
                .clockIn(id: UUID(), profile: WorkdayProfile(target: 3600, expectedRest: 0)),
                matching: current.workActionContext, sample: sample(100)
            )
            let state = try current.reminderState(sample: sample(105))
            _ = try await sync.reconcile(latest: { state }, now: { 105 })
            let external = PendingReminder(id: "unrelated", trigger: 9999, revision: nil, payloadVersion: nil)
            delivery.requests.append(external)

            let cancelled = try await sync.reconcile(latest: {
                do {
                    return try current.reminderState(sample: sample(120, uptime: 105))
                } catch is ApplicationClockError {
                    return nil
                }
            }, now: { 120 })
            #expect(cancelled == .settled)
            #expect(delivery.requests == [external])
        }
    }

    @Test func `checkpoint-only mutation makes old schema two reminder source fail closed`() async throws {
        try await fixture { url in
            let delivery = SchemaTwoReminderDeliveryFake()
            let sync = ReminderSync(delivery: delivery)
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            let id = UUID()
            _ = try current.performConfirmed(
                .clockIn(id: id, profile: WorkdayProfile(target: 3600, expectedRest: 0)),
                matching: current.workActionContext, sample: sample(100)
            )
            let state = try current.reminderState(sample: sample(105))
            _ = try await sync.reconcile(latest: { state }, now: { 105 })
            #expect(delivery.requests.count == 1)

            let repository = try JournalV2Repository(url: url)
            let stored = try repository.load(now: 105)
            let advanced = try repository.saveObservationCheckpoint(
                dayID: id, observedAt: 106, now: 106, matching: stored
            )
            #expect(advanced.version == stored.version)
            await #expect(throws: JournalMigrationError.verificationFailed) {
                try await sync.reconcile(
                    latest: { try current.reminderState(sample: sample(107)) },
                    now: { 107 }
                )
            }
            let cleared = try await sync.reconcile(latest: { nil }, now: { 107 })
            #expect(cleared == .settled)
            #expect(delivery.requests.isEmpty)
        }
    }

    @Test func `notification permission unavailable removes stale owned requests`() async throws {
        try await fixture { url in
            let delivery = SchemaTwoReminderDeliveryFake()
            let sync = ReminderSync(delivery: delivery)
            var current = try JournalV2WorktimeController(
                url: url, createIfMissing: true, sample: sample(100)
            )
            _ = try current.performConfirmed(
                .clockIn(id: UUID(), profile: WorkdayProfile(target: 3600, expectedRest: 0)),
                matching: current.workActionContext, sample: sample(100)
            )
            let state = try current.reminderState(sample: sample(105))
            _ = try await sync.reconcile(latest: { state }, now: { 105 })
            delivery.authorizationValue = .unavailable
            let denied = try await sync.reconcile(latest: { state }, now: { 106 })
            #expect(denied == .permissionUnavailable)
            #expect(delivery.requests.isEmpty)
        }
    }
}
