import Foundation
import Testing
@testable import WorktimeApplication
import WorktimeDomain

@MainActor
private final class FakeReminderDelivery: ReminderDelivery {
    var permission: ReminderAuthorization = .allowed
    var requests: [PendingReminder] = []
    var scheduled: [ReminderRequest] = []
    var removed: [String] = []
    var delayCancellation = false
    var onPending: (() async -> Void)?
    var onSchedule: (() -> Void)?
    var error: ReminderDeliveryError?

    func authorization() async -> ReminderAuthorization {
        permission
    }

    func requestAuthorization() async throws -> Bool {
        permission == .allowed
    }

    func pending() async -> [PendingReminder] {
        await onPending?()
        return requests
    }

    func cancel(ids: [String]) {
        removed.append(contentsOf: ids)
        if !delayCancellation {
            requests.removeAll { ids.contains($0.id) }
        }
    }

    func schedule(_ request: ReminderRequest) async throws {
        if let error {
            throw error
        }
        scheduled.append(request)
        requests.removeAll { $0.id == request.id }
        requests.append(PendingReminder(id: request.id, trigger: request.trigger, revision: request.revision,
                                        payloadVersion: request.payloadVersion))
        onSchedule?()
    }
}

@MainActor
struct ReminderSyncTests {
    private let epoch = UUID()
    private let dayID = UUID()

    private func state(revision: Int64 = 1, target: Int64 = 3600) -> ReminderSyncState {
        let plan = ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: target, estimatedDepartureAt: target), now: 0, clockTrusted: true
        )
        return ReminderSyncState(epoch: epoch, dayID: dayID, revision: revision, desired: plan)
    }

    @Test func `repeated reconciliation is idempotent`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        let value = state()
        let first = try await sync.reconcile(latest: { value }, now: { 0 })
        let second = try await sync.reconcile(latest: { value }, now: { 0 })
        #expect(first == .settled)
        #expect(second == .settled)
        #expect(delivery.scheduled.count == 1)
        #expect(delivery.removed.isEmpty)
    }

    @Test func `replacement waits for cancellation to become observable`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        let first = state()
        let next = state(revision: 2, target: 4200)
        _ = try await sync.reconcile(latest: { first }, now: { 0 })
        delivery.delayCancellation = true
        let blocked = try await sync.reconcile(latest: { next }, now: { 0 })
        #expect(blocked == .cancellationPending)
        #expect(delivery.scheduled.count == 1)
        delivery.delayCancellation = false
        let retried = try await sync.reconcile(latest: { next }, now: { 0 })
        #expect(retried == .settled)
        #expect(delivery.scheduled.map(\.revision) == [1, 2])
    }

    @Test func `changed state during pending read prevents mutations`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        var current = state()
        delivery.onPending = { current = state(revision: 2) }
        let result = try await sync.reconcile(latest: { current }, now: { 0 })
        #expect(result == .superseded)
        #expect(delivery.scheduled.isEmpty)
        #expect(delivery.removed.isEmpty)
    }

    @Test func `changed state during scheduling rolls back newly added requests`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        var current = state()
        delivery.onSchedule = { current = state(revision: 2) }
        let result = try await sync.reconcile(latest: { current }, now: { 0 })
        #expect(result == .superseded)
        #expect(delivery.removed == delivery.scheduled.map(\.id))
        #expect(delivery.requests.isEmpty)
    }

    @Test func `permission denial clears owned but not unrelated pending requests`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        let value = state()
        _ = try await sync.reconcile(latest: { value }, now: { 0 })
        let foreign = PendingReminder(id: "foreign", trigger: 100, revision: nil, payloadVersion: nil)
        delivery.requests.append(foreign)
        delivery.permission = .unavailable
        let result = try await sync.reconcile(latest: { value }, now: { 0 })
        #expect(result == .permissionUnavailable)
        #expect(delivery.requests == [foreign])
    }

    @Test func `reentrant reconciliation returns busy without mutating twice`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        let value = state()
        var nested: ReminderSyncResult?
        delivery.onPending = {
            nested = try? await sync.reconcile(latest: { value }, now: { 0 })
        }
        let result = try await sync.reconcile(latest: { value }, now: { 0 })
        #expect(result == .settled)
        #expect(nested == .busy)
        #expect(delivery.scheduled.count == 1)
    }

    @Test func `known empty plan removes owned notifications`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        let value = state()
        _ = try await sync.reconcile(latest: { value }, now: { 0 })
        let result = try await sync.reconcile(latest: { nil }, now: { 0 })
        #expect(result == .settled)
        #expect(delivery.requests.isEmpty)
    }

    @Test func `elapsed request during reconciliation is not scheduled`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        let value = state()
        var samples = [Int64(0), 2700]
        let result = try await sync.reconcile(latest: { value }, now: { samples.removeFirst() })
        #expect(result == .superseded)
        #expect(delivery.scheduled.isEmpty)
    }

    @Test func `failed state read performs no notification changes`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        await #expect(throws: ReminderDeliveryError.invalidRequest) {
            try await sync.reconcile(latest: { throw ReminderDeliveryError.invalidRequest }, now: { 0 })
        }
        #expect(delivery.scheduled.isEmpty)
        #expect(delivery.removed.isEmpty)
    }

    @Test func `scheduling error is retryable and never sticks busy flag`() async throws {
        let delivery = FakeReminderDelivery()
        let sync = ReminderSync(delivery: delivery)
        let value = state()
        delivery.error = .permissionUnavailable
        await #expect(throws: ReminderDeliveryError.permissionUnavailable) {
            try await sync.reconcile(latest: { value }, now: { 0 })
        }
        delivery.error = nil
        let result = try await sync.reconcile(latest: { value }, now: { 0 })
        #expect(result == .settled)
        #expect(delivery.scheduled.count == 1)
    }
}
