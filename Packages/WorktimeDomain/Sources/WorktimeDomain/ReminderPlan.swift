public enum ReminderLead: Int64, CaseIterable, Sendable {
    case five = 300
    case fifteen = 900
    case thirty = 1800
}

public enum ReminderKind: Hashable, Sendable {
    case departurePreparation(ReminderLead)
    case earliestGoal(ReminderLead)
    case referenceEnd
}

public struct PlannedReminder: Equatable, Sendable {
    public let kind: ReminderKind
    public let trigger: Int64
}

/// Pure desired future requests, not a claim of actual attendance or OS delivery.
public enum ReminderPlan {
    public static func desired(
        forecast: GoalForecast, now: Int64, clockTrusted: Bool,
        departureLeads: Set<ReminderLead> = [.fifteen],
        earliestLeads: Set<ReminderLead> = [], referenceAt: Int64? = nil
    ) -> [PlannedReminder] {
        guard clockTrusted, forecast != .ended else { return [] }
        var result: [PlannedReminder] = []
        if case let .projected(earliest, departure) = forecast, earliest > now, departure >= earliest {
            for lead in ReminderLead.allCases {
                if departureLeads.contains(lead), let trigger = future(departure, lead: lead, now: now) {
                    result.append(PlannedReminder(kind: .departurePreparation(lead), trigger: trigger))
                }
                if earliestLeads.contains(lead), let trigger = future(earliest, lead: lead, now: now) {
                    result.append(PlannedReminder(kind: .earliestGoal(lead), trigger: trigger))
                }
            }
        }
        if let referenceAt, referenceAt > now {
            result.append(PlannedReminder(kind: .referenceEnd, trigger: referenceAt))
        }
        return result
    }

    private static func future(_ target: Int64, lead: ReminderLead, now: Int64) -> Int64? {
        let (trigger, overflow) = target.subtractingReportingOverflow(lead.rawValue)
        return !overflow && trigger > now ? trigger : nil
    }
}
