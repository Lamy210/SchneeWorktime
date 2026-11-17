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

    public init(day: Workday?, enabled: Bool) {
        self.day = day
        self.enabled = enabled
    }

    public func available(at instant: Int64) -> [PanelWorkAction] {
        guard enabled else { return [] }
        guard let day else { return [.start] }
        guard let last = day.intervals.last else { return [] }
        switch day.state {
        case .working:
            return instant > last.start ? [.startBreak, .clockOut] : []
        case .onBreak:
            return instant > last.start ? [.endBreak, .clockOut] : []
        case .ended:
            guard let end = last.end, instant >= end else { return [] }
            return [.start, .resume]
        }
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
