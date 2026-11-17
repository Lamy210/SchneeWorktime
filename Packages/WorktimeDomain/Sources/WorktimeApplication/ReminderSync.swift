import Foundation
import WorktimeDomain

/// A derived plan from the latest successful commit, never a proposed edit.
public struct ReminderSyncState: Equatable, Sendable {
    public let epoch: UUID
    public let dayID: UUID
    public let revision: Int64
    public let desired: [PlannedReminder]

    public init(epoch: UUID, dayID: UUID, revision: Int64, desired: [PlannedReminder]) {
        self.epoch = epoch
        self.dayID = dayID
        self.revision = revision
        self.desired = desired
    }
}

public enum ReminderSyncResult: Equatable, Sendable {
    case settled, busy, superseded, cancellationPending, permissionUnavailable
}

/// One instance per owning application session. Nil state means a known empty plan, not a failed read.
/// The caller owns retries and must only invoke this while holding the local session lock.
@MainActor
public final class ReminderSync {
    private let delivery: any ReminderDelivery
    private var running = false

    public init(delivery: any ReminderDelivery) {
        self.delivery = delivery
    }

    public func reconcile(
        latest: () throws -> ReminderSyncState?, now: () throws -> Int64
    ) async throws -> ReminderSyncResult {
        guard !running else { return .busy }
        running = true
        defer { running = false }
        let state = try latest()
        let permission = await delivery.authorization()
        let pending = await delivery.pending()
        guard try latest() == state else { return .superseded }
        let changes = try plan(state: state, permission: permission, pending: pending, now: now())
        if !changes.cancel.isEmpty {
            delivery.cancel(ids: changes.cancel)
            let remaining = await delivery.pending()
            guard try latest() == state else { return .superseded }
            let cancelled = Set(changes.cancel)
            guard !remaining.contains(where: { cancelled.contains($0.id) }) else { return .cancellationPending }
        }
        if permission != .allowed, state != nil {
            return .permissionUnavailable
        }
        return try await install(changes.upsert, state: state, latest: latest, now: now)
    }

    private func plan(
        state: ReminderSyncState?, permission: ReminderAuthorization, pending: [PendingReminder], now: Int64
    ) throws -> SyncChanges {
        guard let state, permission == .allowed else {
            return SyncChanges(cancel: ReminderNotificationPayload.ownedIDs(pending.map(\.id)), upsert: [])
        }
        let changes = try ReminderReconciliation.changes(
            desired: state.desired, pending: pending, epoch: state.epoch, dayID: state.dayID,
            revision: state.revision, now: now
        )
        return SyncChanges(cancel: changes.cancel, upsert: changes.upsert)
    }

    private func install(
        _ requests: [ReminderRequest], state: ReminderSyncState?,
        latest: () throws -> ReminderSyncState?, now: () throws -> Int64
    ) async throws -> ReminderSyncResult {
        var attempted: [String] = []
        do {
            for request in requests {
                guard try latest() == state, try now() < request.trigger else {
                    cancelAttempted(attempted)
                    return .superseded
                }
                // A delivery error does not prove the OS rejected the request before accepting it.
                attempted.append(request.id)
                try await delivery.schedule(request)
                guard try latest() == state else {
                    cancelAttempted(attempted)
                    return .superseded
                }
            }
            return .settled
        } catch {
            cancelAttempted(attempted)
            throw error
        }
    }

    private func cancelAttempted(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        delivery.cancel(ids: ids)
    }
}

private struct SyncChanges {
    let cancel: [String]
    let upsert: [ReminderRequest]
}
