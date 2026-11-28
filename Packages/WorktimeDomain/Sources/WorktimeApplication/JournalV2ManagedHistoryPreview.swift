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
