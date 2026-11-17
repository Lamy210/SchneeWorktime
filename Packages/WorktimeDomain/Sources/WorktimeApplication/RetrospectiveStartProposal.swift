import Foundation
import WorktimeDomain
import WorktimeStore

public enum RetrospectiveStartError: Error, Equatable {
    case invalidStart, staleProposal
}

/// An explicit assertion of continuous work, not an observation or an automatic inference.
public struct RetrospectiveStartProposal: Sendable {
    let version: StoreVersion
    let command: WorkdayCommand
    public let startedAt: Int64
    public let preparedAt: Int64
    public let preview: WorktimeGlance
}
