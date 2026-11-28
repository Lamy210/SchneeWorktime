import WorktimeStore

public struct JournalV2ManagedHistoryPreview {
    public let context: JournalV2WorkActionContext
    public let scope: ManagedHistoryScopePreview
}

public extension JournalV2WorktimeController {
    /// The view must invalidate this on a context change. Even a matching
    /// context cannot authorize deletion without a new full inventory/CAS.
    func previewManagedHistory(sample: ClockSample) throws -> JournalV2ManagedHistoryPreview {
        var checked = clock
        _ = try checked.advance(to: sample)
        let scope = try repository.previewManagedHistory(now: sample.wall, matching: session)
        return JournalV2ManagedHistoryPreview(context: workActionContext, scope: scope)
    }
}

public enum JournalV2ManagedHistoryPreparation: Equatable, Sendable {
    case initialize, backup
}

public enum JournalV2ManagedHistoryPreparationError: Error, Equatable {
    case stalePreview, unavailable
}

public extension JournalV2WorktimeController {
    /// A distinct, non-destructive operation. A scope preview is not a grant
    /// to delete history. The caller must own the application session lock.
    func prepareManagedHistory(
        _ operation: JournalV2ManagedHistoryPreparation,
        matching expected: JournalV2ManagedHistoryPreview, sample: ClockSample
    ) throws -> JournalV2ManagedHistoryPreview {
        guard expected.context == workActionContext else {
            throw JournalV2ManagedHistoryPreparationError.stalePreview
        }
        let fresh = try previewManagedHistory(sample: sample)
        guard fresh.scope == expected.scope else {
            throw JournalV2ManagedHistoryPreparationError.stalePreview
        }
        switch operation {
        case .initialize:
            guard fresh.scope.state == .notInitialized else {
                throw JournalV2ManagedHistoryPreparationError.unavailable
            }
            try repository.initializeManagedHistory(now: sample.wall, matching: session)
        case .backup:
            guard fresh.scope.state == .inventoried else {
                throw JournalV2ManagedHistoryPreparationError.unavailable
            }
            try repository.createManagedHistoryBackup(now: sample.wall, matching: session)
        }
        return try previewManagedHistory(sample: sample)
    }
}
