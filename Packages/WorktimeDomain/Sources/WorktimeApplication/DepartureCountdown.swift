import Foundation
import WorktimeDomain

/// Presentation derived from the last validated observation, not a second timekeeping clock.
public enum DepartureCountdown: Sendable, Equatable {
    case projected(earliestSeconds: Int64, departureSeconds: Int64)
    case reached, uncertain, onBreak, ended, unavailable

    public init(goal: GoalForecast, observedAt: Int64) {
        switch goal {
        case let .projected(earliest, departure):
            let (first, firstOverflow) = earliest.subtractingReportingOverflow(observedAt)
            let (last, lastOverflow) = departure.subtractingReportingOverflow(observedAt)
            if firstOverflow || lastOverflow || first <= 0 || last < first {
                self = .unavailable
            } else {
                self = .projected(earliestSeconds: first, departureSeconds: last)
            }
        case .reached:
            self = .reached
        case .uncertain:
            self = .uncertain
        case .onBreak:
            self = .onBreak
        case .ended:
            self = .ended
        }
    }

    public var menuTitle: String {
        switch self {
        case let .projected(_, seconds): "退勤まで " + Self.duration(seconds)
        case .reached: "目標達成"
        case .uncertain: "要確認"
        case .onBreak: "休憩中"
        case .ended: "退勤済み"
        case .unavailable: "SchneeWorktime"
        }
    }

    public static func duration(_ seconds: Int64) -> String {
        let value = max(0, seconds)
        return String(format: "%lld:%02lld:%02lld", value / 3600, value / 60 % 60, value % 60)
    }
}
