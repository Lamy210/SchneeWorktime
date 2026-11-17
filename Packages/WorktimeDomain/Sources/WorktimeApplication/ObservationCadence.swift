import WorktimeDomain

/// Presentation polling only. ClockObservation remains the authority on unobserved time.
public enum ObservationCadence: Sendable, Equatable {
    case active, idle

    public init(dayState: WorkdayState?) {
        self = dayState == .working || dayState == .onBreak ? .active : .idle
    }

    public var interval: Double {
        self == .active ? 1 : 5
    }

    public var tolerance: Double {
        self == .active ? 0 : 0.5
    }
}
