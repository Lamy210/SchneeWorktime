import WorktimeStore

public enum HistoricalReviewError: Error, Equatable {
    case staleContext
}

/// A historical selection fenced by the complete store version, including its epoch.
public struct HistoricalReviewContext: Sendable {
    let version: StoreVersion
    public let glance: WorktimeGlance
}
