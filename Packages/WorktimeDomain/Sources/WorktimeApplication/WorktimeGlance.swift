import Foundation
import WorktimeDomain

public struct WorktimeGlance: Sendable {
    public let day: Workday
    public let snapshot: TimelineSnapshot
    public let forecast: DailyForecast
    public let reviewableGaps: [ObservationGap]
    public let observedAt: Int64
    public let desiredDepartureAt: Int64?

    public init(catalog: WorkdayCatalog, now: Int64, dayID: UUID? = nil) throws {
        let selected = if let dayID {
            catalog.days.first(where: { $0.id == dayID })
        } else {
            catalog.days.last
        }
        guard let day = selected else { throw WorkdayError.noActiveDay }
        let snapshot = try catalog.snapshot(dayID: day.id, now: now)
        let state: PreviewState = switch day.state {
        case .working: .working
        case .onBreak: .onBreak(returnAt: nil)
        case .ended: .ended
        }
        self.day = day
        desiredDepartureAt = catalog.desiredDepartures[day.id]
        observedAt = now
        self.snapshot = snapshot
        reviewableGaps = Self.reviewable(day: day, gaps: catalog.observations[day.id] ?? [], now: now)
        forecast = try DailyForecast.calculate(
            worked: snapshot.bounds.lower ... snapshot.bounds.upper,
            target: day.profile.target, remainingRest: snapshot.remainingRest, now: now, state: state
        )
    }

    private static func reviewable(day: Workday, gaps: [ObservationGap], now: Int64) -> [ObservationGap] {
        day.intervals.filter { $0.kind == .work }.flatMap { interval in
            gaps.compactMap { gap in
                let start = max(interval.start, gap.start)
                let end = min(interval.end ?? now, gap.end)
                return start < end ? ObservationGap(start: start, end: end) : nil
            }
        }
    }
}
