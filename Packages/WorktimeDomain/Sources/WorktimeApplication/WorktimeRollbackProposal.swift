import WorktimeStore

public struct WorktimeRollbackProposal: Sendable {
    let stored: CatalogRollbackProposal

    public var currentDays: Int {
        stored.currentDays
    }

    public var restoredDays: Int {
        stored.restoredDays
    }

    public var currentRevision: Int64 {
        stored.currentVersion.revision
    }

    public var sourceRevision: Int64 {
        stored.sourceVersion.revision
    }
}
