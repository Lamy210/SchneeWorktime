import WorktimeDomain
import WorktimeStore

public enum RestEndInteractionError: Error, Equatable {
    case staleProposal
}

public struct WorktimeRestEndProposal: Sendable {
    let stored: StoredRestEndCorrection
    public let before: WorktimeGlance
    public let after: WorktimeGlance

    public var boundary: RestBoundary {
        stored.preview.boundary
    }

    public var oldEnd: Int64 {
        stored.preview.oldEnd
    }

    public var newEnd: Int64 {
        stored.preview.newEnd
    }
}
