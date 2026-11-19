import WorktimeStore

public enum ClockOutInteractionError: Error, Equatable {
    case staleProposal
}

public struct WorktimeClockOutProposal: Sendable {
    let stored: StoredClockOutCorrection
    public let before: WorktimeGlance
    public let after: WorktimeGlance

    public var oldEnd: Int64 {
        stored.preview.oldEnd
    }

    public var newEnd: Int64 {
        stored.preview.newEnd
    }
}
