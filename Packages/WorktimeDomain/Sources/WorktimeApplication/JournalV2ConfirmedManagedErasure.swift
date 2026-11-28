import WorktimeStore

package enum JournalV2ConfirmedManagedErasureError: Error, Equatable {
    case staleConfirmation, missingConsent, notificationsNotSettled
}

/// Separate from the count-only scope preview and the DB-only reset.
package struct JournalV2ConfirmedManagedErasure {
    package let context: JournalV2WorkActionContext
    package var scope: ManagedHistoryScopePreview { plan.scope }
    let plan: JournalV2ManagedErasurePlan
}

package extension JournalV2WorktimeController {
    func previewConfirmedManagedErasure(
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> JournalV2ConfirmedManagedErasure {
        guard expected == workActionContext else {
            throw JournalV2ConfirmedManagedErasureError.staleConfirmation
        }
        var checked = clock
        _ = try checked.advance(to: sample)
        let plan = try repository.previewManagedErasure(now: sample.wall, matching: session)
        return JournalV2ConfirmedManagedErasure(context: expected, plan: plan)
    }

    /// Caller must own the session lock, stop writers and independently settle
    /// owned notifications. This flag is a caller assertion, not OS evidence.
    /// On *any* error after starting, discard the controller; never retry the
    /// initial path. A separate recovery flow must inspect durable markers.
    mutating func commitConfirmedManagedErasure(
        _ confirmation: JournalV2ConfirmedManagedErasure, consent: String,
        notificationsSettled: Bool, sample: ClockSample
    ) throws {
        guard consent == "全履歴削除" else { throw JournalV2ConfirmedManagedErasureError.missingConsent }
        guard notificationsSettled else { throw JournalV2ConfirmedManagedErasureError.notificationsNotSettled }
        guard confirmation.context == workActionContext else {
            throw JournalV2ConfirmedManagedErasureError.staleConfirmation
        }
        var checked = clock
        _ = try checked.advance(to: sample)
        session = try repository.beginManagedErasure(confirmation.plan, now: sample.wall, matching: session)
        clock = checked
        try repository.finishManagedErasure(confirmation.plan, now: sample.wall)
    }
}
