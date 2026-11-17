import Foundation
import Testing
@testable import WorktimeApplication
import WorktimeDomain

struct ReminderDeliveryTests {
    private func request() throws -> ReminderRequest {
        let desired = ReminderPlan.desired(
            forecast: .projected(earliestGoalAt: 3600, estimatedDepartureAt: 3600), now: 0, clockTrusted: true
        )
        let changes = try ReminderReconciliation.changes(
            desired: desired, pending: [], epoch: UUID(), dayID: UUID(), revision: 1, now: 0
        )
        return try #require(changes.upsert.first)
    }

    @Test func `payload round trip preserves trigger and revision`() throws {
        let request = try request()
        let fields = ReminderNotificationPayload.fields(for: request)
        let pending = ReminderNotificationPayload.pending(
            id: request.id, actualTrigger: request.trigger, fields: fields
        )
        #expect(pending.trigger == request.trigger)
        #expect(pending.revision == request.revision)
        #expect(pending.payloadVersion == request.payloadVersion)
        #expect(Set(fields.keys) == ["trigger", "revision", "payloadVersion"])
    }

    @Test func `wrong or missing OS trigger is never accepted`() throws {
        let request = try request()
        let fields = ReminderNotificationPayload.fields(for: request)
        for actual in [nil, request.trigger + 1] as [Int64?] {
            let pending = ReminderNotificationPayload.pending(id: request.id, actualTrigger: actual, fields: fields)
            #expect(pending.trigger == nil)
            #expect(pending.revision == nil)
        }
    }

    @Test func `invalid metadata fails closed`() throws {
        let request = try request()
        let original = ReminderNotificationPayload.fields(for: request)
        for (key, value) in [("revision", "-1"), ("revision", "01"), ("payloadVersion", "0"), ("trigger", "x")] {
            var fields = original
            fields[key] = value
            let pending = ReminderNotificationPayload.pending(
                id: request.id, actualTrigger: request.trigger, fields: fields
            )
            #expect(pending.trigger == nil)
        }
    }

    @Test func `cancellation preserves foreign notifications and deduplicates owned IDs`() {
        let owned = ReminderReconciliation.ownedPrefix + "test"
        #expect(ReminderNotificationPayload.ownedIDs([owned, "foreign", owned]) == [owned])
    }

    @Test func `notification copy contains no actual attendance or precise times`() {
        #expect(ReminderNotificationPayload.body(for: .departurePreparation(.fifteen)) == "退勤見込みを確認する時間です。")
        #expect(ReminderNotificationPayload.body(for: .earliestGoal(.five)) == "実働目標の見込みを確認してください。")
        #expect(ReminderNotificationPayload.body(for: .referenceEnd) == "設定した参考時刻です。")
    }
}
