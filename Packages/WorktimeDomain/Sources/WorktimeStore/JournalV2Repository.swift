import Foundation
import WorktimeDomain

/// A validated schema-2 session with its complete, opaque event and checkpoint CAS fence.
/// Always pass the returned session to mutations; epoch/revision alone cannot fence a
/// checkpoint-only write at an unchanged revision.
public struct JournalV2Session {
    public let version: StoreVersion
    public let catalog: WorkdayCatalog
    public let checkpoint: ObservationCheckpoint?
    fileprivate let source: JournalV2LiveState

    fileprivate init(_ source: JournalV2LiveState) {
        version = source.version
        catalog = source.catalog
        checkpoint = source.checkpoint
        self.source = source
    }
}

/// A new-install-only repository. No implicit schema-1 conversion, erase or recovery.
/// The application coordinator must own its private directory/session lock.
public struct JournalV2Repository {
    private let store: JournalV2LiveStore

    public init(url: URL, createIfMissing: Bool = false) throws {
        store = try JournalV2LiveStore(url: url, createIfMissing: createIfMissing)
    }

    public func load(now: Int64) throws -> JournalV2Session {
        try JournalV2Session(store.load(now: now))
    }

    /// A checkpoint update at the same revision still invalidates the prior session.
    public func revalidate(_ cached: JournalV2Session, now: Int64) throws -> JournalV2Session {
        let current = try store.load(now: now)
        guard current.version == cached.version else { throw SnapshotStoreError.staleVersion }
        guard Self.matches(current, cached.source) else {
            throw JournalMigrationError.verificationFailed
        }
        return JournalV2Session(current)
    }

    public func apply(
        _ command: WorkdayCommand, at instant: Int64, now: Int64,
        matching session: JournalV2Session, observedAt: Int64? = nil
    ) throws -> JournalV2Session {
        try mutate(
            JournalEvent(action: .command(JournalCommand(command), at: instant), now: now),
            matching: session, observedAt: observedAt
        )
    }

    public func recordObservation(
        dayID: UUID, gap: ObservationGap, now: Int64,
        matching session: JournalV2Session, observedAt: Int64? = nil
    ) throws -> JournalV2Session {
        try mutate(
            JournalEvent(action: .observation(dayID: dayID, start: gap.start, end: gap.end), now: now),
            matching: session, observedAt: observedAt
        )
    }

    public func setFutureRest(
        dayID: UUID, remainingSeconds: Int64?, now: Int64, matching session: JournalV2Session,
        observedAt: Int64? = nil
    ) throws -> JournalV2Session {
        try mutate(
            JournalEvent(action: .futureRest(dayID: dayID, remainingSeconds: remainingSeconds), now: now),
            matching: session, observedAt: observedAt
        )
    }

    public func setDesiredDeparture(
        dayID: UUID, candidate: Int64?, warningAcknowledged: Bool, now: Int64,
        matching session: JournalV2Session, observedAt: Int64? = nil
    ) throws -> JournalV2Session {
        let action = JournalAction.desiredDeparture(
            dayID: dayID, candidate: candidate, warningAcknowledged: warningAcknowledged
        )
        return try mutate(JournalEvent(action: action, now: now), matching: session, observedAt: observedAt)
    }

    public func saveObservationCheckpoint(
        dayID: UUID, observedAt: Int64, now: Int64, matching session: JournalV2Session
    ) throws -> JournalV2Session {
        try JournalV2Session(store.saveObservationCheckpoint(
            dayID: dayID, observedAt: observedAt, matching: session.source, now: now
        ))
    }

    /// Only called with a domain-validated preview bound to an exact loaded session.
    /// A replay of the proposed event must produce precisely the previewed catalog.
    func commitVerified(
        _ event: JournalEvent, matching session: JournalV2Session,
        previewedCatalog: WorkdayCatalog
    ) throws -> JournalV2Session {
        let current = try revalidate(session, now: event.now)
        var replayed = current.catalog
        try event.apply(to: &replayed)
        guard replayed == previewedCatalog, replayed != current.catalog else {
            throw JournalMigrationError.verificationFailed
        }
        return try mutate(event, matching: session, observedAt: nil)
    }

    private func mutate(
        _ event: JournalEvent, matching session: JournalV2Session, observedAt: Int64?
    ) throws -> JournalV2Session {
        let current = try revalidate(session, now: event.now)
        var next = current.catalog
        try event.apply(to: &next)
        if next == current.catalog {
            guard observedAt == nil else { throw ObservationCheckpointError.invalid }
            return current
        }
        let committed = try store.append(
            event, matching: session.source, now: event.now, observedAt: observedAt
        )
        return JournalV2Session(committed)
    }

    fileprivate static func matches(_ current: JournalV2LiveState, _ expected: JournalV2LiveState) -> Bool {
        current.version == expected.version &&
            current.rows == expected.rows &&
            current.catalog == expected.catalog &&
            current.checkpoint == expected.checkpoint
    }
}

public struct JournalV2ResetPreview {
    public let version: StoreVersion
    public let workdays: Int
    public let corrections: Int
    public let hasActiveWorkday: Bool
    fileprivate let session: JournalV2Session
}

public extension JournalV2Repository {
    /// Read-only preview. Caller must stop writers/notifications and obtain explicit
    /// user confirmation before commit; app-managed backup cleanup is not implemented here.
    func previewReset(now: Int64, matching session: JournalV2Session) throws -> JournalV2ResetPreview {
        let current = try revalidate(session, now: now)
        return JournalV2ResetPreview(
            version: current.version, workdays: current.catalog.days.count,
            corrections: current.catalog.reviewAudit.count,
            hasActiveWorkday: current.catalog.activeID != nil, session: current
        )
    }

    /// Logical deletion only. Does not claim physical erasure or delete owned backups.
    func commitReset(_ preview: JournalV2ResetPreview, now: Int64) throws -> JournalV2Session {
        _ = try revalidate(preview.session, now: now)
        return try JournalV2Session(store.reset(matching: preview.session.source, now: now))
    }
}
