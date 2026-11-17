import Foundation
import Testing
@testable import WorktimeDomain

struct ReminderReconciliationTests {
    private let epoch = UUID()
    private let dayID = UUID()

    private func plan(_ at: Int64 = 3600) -> [PlannedReminder] {
        ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: at, estimatedDepartureAt: at), now: 0, clockTrusted: true
        )
    }

    private func changes(
        _ desired: [PlannedReminder], _ pending: [PendingReminder] = [], revision: Int64 = 1, now: Int64 = 0
    ) throws -> ReminderChanges {
        try ReminderReconciliation.changes(
            desired: desired, pending: pending, epoch: epoch, dayID: dayID, revision: revision, now: now
        )
    }

    private func pending(_ request: ReminderRequest) -> PendingReminder {
        PendingReminder(id: request.id, trigger: request.trigger, revision: request.revision,
                        payloadVersion: request.payloadVersion)
    }

    @Test func `initial plan and repeated reconciliation converge`() throws {
        let first = try changes(plan())
        #expect(first.cancel.isEmpty)
        #expect(first.upsert.count == 1)
        let second = try changes(plan(), first.upsert.map(pending))
        #expect(second.cancel.isEmpty)
        #expect(second.upsert.isEmpty)
    }

    @Test func `same identifier with changed trigger or revision is replaced`() throws {
        let original = try #require(changes(plan()).upsert.first)
        for next in [try changes(plan(4200), [pending(original)]),
                     try changes(plan(), [pending(original)], revision: 2)] {
            #expect(next.cancel == [original.id])
            #expect(next.upsert.map(\.id) == [original.id])
        }
    }

    @Test func `empty desired removes owned requests but leaves foreign requests untouched`() throws {
        let original = try #require(changes(plan()).upsert.first)
        let foreign = PendingReminder(id: "other.app", trigger: 100, revision: nil, payloadVersion: nil)
        let next = try changes([], [pending(original), foreign])
        #expect(next.cancel == [original.id])
        #expect(next.upsert.isEmpty)
    }

    @Test func `stale epoch and day requests are removed`() throws {
        let original = try #require(changes(plan()).upsert.first)
        for (newEpoch, newDay) in [(UUID(), dayID), (epoch, UUID())] {
            let next = try ReminderReconciliation.changes(
                desired: plan(), pending: [pending(original)], epoch: newEpoch, dayID: newDay, revision: 1, now: 0
            )
            #expect(next.cancel == [original.id])
            #expect(next.upsert.count == 1)
            #expect(next.upsert.first?.id != original.id)
        }
    }

    @Test func `malformed or duplicate pending metadata triggers replacement`() throws {
        let original = try #require(changes(plan()).upsert.first)
        let malformed = PendingReminder(id: original.id, trigger: original.trigger, revision: nil, payloadVersion: 0)
        for existing in [[malformed], [pending(original), pending(original)]] {
            let next = try changes(plan(), existing)
            #expect(next.cancel == [original.id])
            #expect(next.upsert == [original])
        }
    }

    @Test func `elapsed desired triggers are not reinstalled`() throws {
        let original = try #require(changes(plan()).upsert.first)
        let next = try changes(plan(), [pending(original)], now: original.trigger)
        #expect(next.cancel == [original.id])
        #expect(next.upsert.isEmpty)
    }

    @Test func `invalid revision and duplicate desired kind fail without changes`() {
        #expect(throws: ReminderReconciliationError.invalidRevision) {
            try changes(plan(), revision: -1)
        }
        #expect(throws: ReminderReconciliationError.duplicateKind) {
            try changes(plan() + plan())
        }
    }
}
