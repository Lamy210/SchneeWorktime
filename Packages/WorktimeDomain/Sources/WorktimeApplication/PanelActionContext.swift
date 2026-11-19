import Foundation
import WorktimeDomain

public enum PanelWorkAction: String, Sendable, CaseIterable {
    case start, startBreak, endBreak, clockOut, resume

    public var title: String {
        switch self {
        case .start: "勤務開始"
        case .startBreak: "休憩開始"
        case .endBreak: "休憩終了"
        case .clockOut: "退勤"
        case .resume: "直前の勤務を再開"
        }
    }
}

/// A confirmation is tied to the exact displayed workday, not just its current state.
public struct PanelActionContext: Sendable, Equatable {
    public let day: Workday?
    public let enabled: Bool
    public let canOpenWorkday: Bool
    public let canChangeBreak: Bool
    public let canClockOut: Bool

    public init(
        day: Workday?, enabled: Bool, canOpenWorkday: Bool = true,
        canChangeBreak: Bool = true, canClockOut: Bool = true
    ) {
        self.day = day
        self.enabled = enabled
        self.canOpenWorkday = canOpenWorkday
        self.canChangeBreak = canChangeBreak
        self.canClockOut = canClockOut
    }

    public func available(at instant: Int64) -> [PanelWorkAction] {
        guard enabled else { return [] }
        guard let day else { return canOpenWorkday ? [.start] : [] }
        guard let last = day.intervals.last else { return [] }
        switch day.state {
        case .working:
            return activeActions(.startBreak, afterStart: instant > last.start)
        case .onBreak:
            return activeActions(.endBreak, afterStart: instant > last.start)
        case .ended:
            guard let end = last.end, instant >= end else { return [] }
            return canOpenWorkday ? [.start, .resume] : []
        }
    }

    private func activeActions(_ breakAction: PanelWorkAction, afterStart: Bool) -> [PanelWorkAction] {
        guard afterStart else { return [] }
        var actions: [PanelWorkAction] = []
        if canChangeBreak { actions.append(breakAction) }
        if canClockOut { actions.append(.clockOut) }
        return actions
    }

    /// Reject commands captured from an older view or confirmation.
    public func command(
        for action: PanelWorkAction, matching expected: Self, at instant: Int64,
        confirmed: Bool = false, profile: WorkdayProfile? = nil
    ) -> WorkdayCommand? {
        guard self == expected else { return nil }
        return command(for: action, at: instant, confirmed: confirmed, profile: profile)
    }

    public func command(
        for action: PanelWorkAction, at instant: Int64, confirmed: Bool = false,
        profile: WorkdayProfile? = nil, newID: UUID = UUID()
    ) -> WorkdayCommand? {
        guard available(at: instant).contains(action) else { return nil }
        switch action {
        case .start:
            guard let profile else { return nil }
            return .clockIn(id: newID, profile: profile)
        case .startBreak:
            return .startBreak
        case .endBreak:
            return .endBreak
        case .clockOut:
            guard confirmed else { return nil }
            return .clockOut(confirmBreak: day?.state == .onBreak)
        case .resume:
            guard let id = day?.id else { return nil }
            return .resume(id: id)
        }
    }
}
