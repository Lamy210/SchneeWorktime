import Foundation

public enum CatalogRollbackError: Error, Equatable {
    case differentGeneration, notEarlier, activeWorkday, divergentHistory, preservationFailed
}

/// Read-only preview for a healthy store. Only exact earlier journal prefixes are eligible.
/// Keep the validated bytes in memory so confirmation never reopens a substituted input file.
public struct CatalogRollbackProposal: Sendable {
    let source: StoredSnapshot
    let currentSnapshot: StoredSnapshot
    public let currentVersion: StoreVersion
    public let currentDays: Int
    public let restoredDays: Int

    public var sourceVersion: StoreVersion {
        source.version
    }
}
