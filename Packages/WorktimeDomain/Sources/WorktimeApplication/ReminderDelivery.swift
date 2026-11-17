import Foundation
import WorktimeDomain

public enum ReminderAuthorization: Sendable, Equatable {
    case notDetermined, unavailable, allowed
}

public enum ReminderDeliveryError: Error, Equatable {
    case invalidRequest, permissionUnavailable, expired
}

@MainActor
public protocol ReminderDelivery {
    func authorization() async -> ReminderAuthorization
    func requestAuthorization() async throws -> Bool
    func pending() async -> [PendingReminder]
    func cancel(ids: [String])
    func schedule(_ request: ReminderRequest) async throws
}

/// Only opaque version metadata and generic notification text; no attendance details.
public enum ReminderNotificationPayload {
    public static func fields(for request: ReminderRequest) -> [String: String] {
        ["trigger": String(request.trigger), "revision": String(request.revision),
         "payloadVersion": String(request.payloadVersion)]
    }

    public static func pending(id: String, actualTrigger: Int64?, fields: [String: String]) -> PendingReminder {
        guard id.hasPrefix(ReminderReconciliation.ownedPrefix),
              let actualTrigger, let trigger = parse(fields["trigger"]), trigger == actualTrigger,
              let revision = parse(fields["revision"]), revision >= 0,
              let version = parse(fields["payloadVersion"]), version == Int64(ReminderReconciliation.payloadVersion)
        else {
            return PendingReminder(id: id, trigger: nil, revision: nil, payloadVersion: nil)
        }
        return PendingReminder(id: id, trigger: trigger, revision: revision, payloadVersion: Int(version))
    }

    public static func body(for kind: ReminderKind) -> String {
        switch kind {
        case .departurePreparation: "退勤見込みを確認する時間です。"
        case .earliestGoal: "実働目標の見込みを確認してください。"
        case .referenceEnd: "設定した参考時刻です。"
        }
    }

    public static func ownedIDs(_ ids: [String]) -> [String] {
        Array(Set(ids.filter { $0.hasPrefix(ReminderReconciliation.ownedPrefix) })).sorted()
    }

    private static func parse(_ value: String?) -> Int64? {
        guard let value, let parsed = Int64(value), String(parsed) == value else { return nil }
        return parsed
    }
}
