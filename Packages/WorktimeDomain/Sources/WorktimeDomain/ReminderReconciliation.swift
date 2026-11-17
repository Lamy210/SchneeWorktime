import Foundation

public struct ReminderRequest: Sendable, Equatable {
    public let id: String
    public let kind: ReminderKind
    public let trigger: Int64
    public let revision: Int64
    public let payloadVersion: Int
}

/// The OS adapter must decode unknown or malformed metadata as nil, never as a valid request.
public struct PendingReminder: Sendable, Equatable {
    public let id: String
    public let trigger: Int64?
    public let revision: Int64?
    public let payloadVersion: Int?

    public init(id: String, trigger: Int64?, revision: Int64?, payloadVersion: Int?) {
        self.id = id
        self.trigger = trigger
        self.revision = revision
        self.payloadVersion = payloadVersion
    }
}

public struct ReminderChanges: Sendable, Equatable {
    public let cancel: [String]
    public let upsert: [ReminderRequest]
}

public enum ReminderReconciliationError: Error, Equatable {
    case invalidRevision, duplicateKind
}

/// Plans changes only. Callers must serialize OS operations and recheck the latest committed state.
public enum ReminderReconciliation {
    public static let ownedPrefix = "schneeworktime.reminder."
    public static let payloadVersion = 1

    public static func changes(
        desired: [PlannedReminder], pending: [PendingReminder], epoch: UUID, dayID: UUID,
        revision: Int64, now: Int64
    ) throws -> ReminderChanges {
        guard revision >= 0 else { throw ReminderReconciliationError.invalidRevision }
        var requests: [String: ReminderRequest] = [:]
        var seen: Set<ReminderKind> = []
        for reminder in desired {
            guard seen.insert(reminder.kind).inserted else { throw ReminderReconciliationError.duplicateKind }
            guard reminder.trigger > now else { continue }
            let id = ownedPrefix + epoch.uuidString + "." + dayID.uuidString + "." + suffix(reminder.kind)
            requests[id] = ReminderRequest(
                id: id, kind: reminder.kind, trigger: reminder.trigger, revision: revision,
                payloadVersion: payloadVersion
            )
        }
        let owned = Dictionary(grouping: pending.filter { $0.id.hasPrefix(ownedPrefix) }, by: \.id)
        var cancel: [String] = []
        var upsert: [ReminderRequest] = []
        for (id, existing) in owned {
            guard let request = requests[id], existing.count == 1,
                  existing.first?.trigger == request.trigger, existing.first?.revision == request.revision,
                  existing.first?.payloadVersion == request.payloadVersion
            else {
                cancel.append(id)
                continue
            }
            requests.removeValue(forKey: id)
        }
        upsert.append(contentsOf: requests.values)
        return ReminderChanges(cancel: cancel.sorted(), upsert: upsert.sorted { $0.id < $1.id })
    }

    private static func suffix(_ kind: ReminderKind) -> String {
        switch kind {
        case let .departurePreparation(lead): "departure.\(lead.rawValue)"
        case let .earliestGoal(lead): "earliest.\(lead.rawValue)"
        case .referenceEnd: "reference"
        }
    }
}
