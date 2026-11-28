import Foundation
import WorktimeDomain

/// A validated schema-2 session with its complete, opaque event and checkpoint CAS fence.
/// Always pass the returned session to mutations; epoch/revision alone cannot fence a
/// checkpoint-only write at an unchanged revision.
public struct JournalV2Session {
    public let version: StoreVersion
    public let catalog: WorkdayCatalog
    public let checkpoint: ObservationCheckpoint?

    /// schema-2 has a 100,000-row journal budget, distinct from the schema-1 limit.
    public var journalCapacity: JournalCapacity {
        JournalCapacity(revision: version.revision, limit: Int64(JournalRowCodec.maxRows))
    }

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
    private let databaseURL: URL

    public init(
        url: URL, createIfMissing: Bool = false, requireNew: Bool = false
    ) throws {
        databaseURL = try DatabaseFileGuard.canonicalURL(url)
        store = try JournalV2LiveStore(
            url: databaseURL, createIfMissing: createIfMissing, requireNew: requireNew
        )
    }

    /// Full replay under SQLITE_OPEN_READONLY and query_only, without recovery
    /// writes or a mutable repository session. Caller owns the app session lock.
    public static func inspectReadOnly(url: URL, now: Int64) throws -> JournalV2Session {
        try JournalV2Session(JournalV2LiveStore.inspectReadOnly(url: url, now: now))
    }

    /// Compare the exact event rows, epoch/revision, replayed catalog and
    /// observation checkpoint. Equality of revision alone is insufficient.
    public static func sameCommittedState(
        _ expected: JournalV2Session, _ actual: JournalV2Session
    ) -> Bool {
        matches(actual.source, expected.source)
    }

    /// Re-read the entire Journal without a writable SQLite handle.
    /// A stale inspection must never be treated as a current backup source.
    public static func revalidateReadOnly(
        url: URL, now: Int64, matching expected: JournalV2Session
    ) throws -> JournalV2Session {
        let current = try inspectReadOnly(url: url, now: now)
        guard current.version == expected.version else { throw SnapshotStoreError.staleVersion }
        guard sameCommittedState(expected, current) else {
            throw JournalMigrationError.verificationFailed
        }
        return current
    }

    /// Export the exact displayed read-only generation, without recovering
    /// observations or opening the live SQLite file for writing. Destination
    /// must be outside the application-owned live database directory tree.
    public static func writeReadOnlyBackup(
        from url: URL, to destination: URL, now: Int64, matching expected: JournalV2Session
    ) throws {
        let sourceDirectory = try DatabaseFileGuard.canonicalURL(url)
            .deletingLastPathComponent().pathComponents
        let destinationDirectory = destination.deletingLastPathComponent()
            .resolvingSymlinksInPath().pathComponents
        guard destination.isFileURL, !destinationDirectory.starts(with: sourceDirectory) else {
            throw BackupFileError.invalidDestination
        }
        let current = try revalidateReadOnly(url: url, now: now, matching: expected)
        let bytes = try JournalV2Backup.encode(current.source, now: now)
        try BackupFile.publish(bytes, to: destination, maxBytes: JournalV2Backup.maxBytes)
        // Do not delete an archive when a publication/readback is ambiguous.
        guard try BackupFile.load(destination, maxBytes: JournalV2Backup.maxBytes) == bytes else {
            throw JournalV2BackupError.invalidArchive
        }
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

    /// Captures only an exact, still-current schema-2 generation. The observation
    /// checkpoint is deliberately excluded: it must not be treated as fresh after restore.
    public func makeBackup(now: Int64, matching session: JournalV2Session) throws -> Data {
        let current = try revalidate(session, now: now)
        return try JournalV2Backup.encode(current.source, now: now)
    }

    /// Publishes an immutable plaintext archive into a private owner-only directory.
    /// Fails rather than overwriting an existing backup; no live DB mutation is performed.
    public func writeBackup(
        to destination: URL, now: Int64, matching session: JournalV2Session
    ) throws {
        let data = try makeBackup(now: now, matching: session)
        try BackupFile.publish(data, to: destination, maxBytes: JournalV2Backup.maxBytes)
        // A failed readback after durable publication is ambiguous, never delete or retry blindly.
        guard try BackupFile.load(destination, maxBytes: JournalV2Backup.maxBytes) == data else {
            throw JournalV2BackupError.invalidArchive
        }
    }

    /// Only called with a domain-validated preview bound to an exact loaded session.
    /// A replay of the proposed event must produce precisely the previewed catalog.
    func commitVerified(
        _ event: JournalEvent, matching session: JournalV2Session,
        previewedCatalog: WorkdayCatalog, observedAt: Int64? = nil
    ) throws -> JournalV2Session {
        let current = try revalidate(session, now: event.now)
        var replayed = current.catalog
        try event.apply(to: &replayed)
        guard replayed == previewedCatalog, replayed != current.catalog else {
            throw JournalMigrationError.verificationFailed
        }
        return try mutate(event, matching: session, observedAt: observedAt)
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
        guard try !ManagedHistoryStartupFence.hasPending(in: databaseURL.deletingLastPathComponent()) else {
            throw ManagedHistoryPersistenceError.pendingIntent
        }
        _ = try revalidate(preview.session, now: now)
        return try JournalV2Session(store.reset(matching: preview.session.source, now: now))
    }
}

extension JournalV2Repository {
    /// Internal, explicitly confirmed operation only. Caller holds the owner
    /// lock and has stopped writers/notifications. Not connected to the UI.
    /// The intent is never cleared here, including on uncertain failures.
    func commitManagedReset(
        _ preview: JournalV2ResetPreview, intent: ManagedHistoryErasureIntent, now: Int64
    ) throws -> JournalV2Session {
        let current = try revalidate(preview.session, now: now)
        guard current.version.epoch == intent.sourceEpoch, current.version.revision == intent.sourceRevision else {
            throw ManagedHistoryPersistenceError.invalidIntent
        }
        let directory = databaseURL.deletingLastPathComponent()
        guard try !ManagedHistoryStartupFence.hasPending(in: directory) else {
            throw ManagedHistoryPersistenceError.pendingIntent
        }
        try ManagedHistoryErasureIntentFile.publish(intent, in: directory)
        let registry = try ManagedHistoryRegistryFile.load(in: directory)
        let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: directory, registry: registry)
        guard try ManagedHistoryErasureIntentFile.load(in: directory) == intent,
              intent.assess(session: current, registry: registry, inventory: inventory) == .needsNewConfirmation
        else { throw ManagedHistoryPersistenceError.verificationFailed }
        // The existing transaction verifies the complete Journal and checkpoint
        // again. No recovery path is allowed to reconstruct a stale preview.
        return try JournalV2Session(store.reset(
            matching: current.source, now: now, targetEpoch: intent.targetEpoch
        ))
    }
}

public struct JournalV2RollbackProposal {
    public let currentVersion: StoreVersion
    public let sourceVersion: StoreVersion
    public let currentDays: Int
    public let restoredDays: Int
    fileprivate let session: JournalV2Session
    fileprivate let candidate: JournalV2RestorableBackup
}

public extension JournalV2Repository {
    /// Preview one private schema-2 backup; no files or databases are modified.
    func previewRollback(
        file: URL, now: Int64, matching session: JournalV2Session
    ) throws -> JournalV2RollbackProposal {
        try previewRollback(
            from: BackupFile.load(file, maxBytes: JournalV2Backup.maxBytes),
            now: now, matching: session
        )
    }

    /// Accept only exact historical prefixes from this healthy, ended generation.
    /// Captured row bytes are used at commit instead of reopening a replaceable archive file.
    func previewRollback(
        from data: Data, now: Int64, matching session: JournalV2Session
    ) throws -> JournalV2RollbackProposal {
        let current = try revalidate(session, now: now)
        let candidate = try JournalV2Backup.decodeValidated(data, now: now)
        try Self.verifyRollbackCandidate(candidate, against: current)
        return JournalV2RollbackProposal(
            currentVersion: current.version, sourceVersion: candidate.version,
            currentDays: current.catalog.days.count, restoredDays: candidate.catalog.days.count,
            session: current, candidate: candidate
        )
    }

    /// Caller must explicitly confirm, quiesce writers/notifications, and provide
    /// a *new* owner-only preservation destination outside the database directory.
    /// A failed preservation aborts before any live DB change.
    func commitRollback(
        _ proposal: JournalV2RollbackProposal, preserveCurrentAt destination: URL, now: Int64
    ) throws -> JournalV2Session {
        let current = try revalidate(proposal.session, now: now)
        try Self.verifyRollbackCandidate(proposal.candidate, against: current)

        let sourceDirectory = databaseURL.deletingLastPathComponent().pathComponents
        let destinationDirectory = destination.deletingLastPathComponent()
            .resolvingSymlinksInPath().pathComponents
        guard !destinationDirectory.starts(with: sourceDirectory) else {
            throw BackupFileError.invalidDestination
        }

        // Verify and durably preserve the exact committed generation, then verify again
        // inside the SQLite write transaction to reject any concurrent mutation.
        try writeBackup(to: destination, now: now, matching: current)
        let restored = try store.replaceForRollback(
            proposal.candidate, matching: current.source, now: now
        )
        return JournalV2Session(restored)
    }

    private static func verifyRollbackCandidate(
        _ candidate: JournalV2RestorableBackup, against current: JournalV2Session
    ) throws {
        guard candidate.version.epoch == current.version.epoch else {
            throw CatalogRollbackError.differentGeneration
        }
        guard candidate.version.revision > 0,
              candidate.version.revision < current.version.revision
        else { throw CatalogRollbackError.notEarlier }
        guard current.catalog.activeID == nil, candidate.catalog.activeID == nil else {
            throw CatalogRollbackError.activeWorkday
        }
        guard current.source.rows.prefix(candidate.rows.count).elementsEqual(candidate.rows) else {
            throw CatalogRollbackError.divergentHistory
        }
    }
}

extension JournalV2Repository {
    /// Produce an exact validated backup inside the initialized managed root.
    /// Caller owns the session lock; external exports remain separate.
    func writeManagedBackup(now: Int64, matching session: JournalV2Session) throws -> ManagedHistoryEntry {
        let current = try revalidate(session, now: now)
        let data = try makeBackup(now: now, matching: current)
        return try ManagedHistoryBackupWriter.publish(
            data, epoch: current.version.epoch, in: databaseURL.deletingLastPathComponent()
        )
    }
}

public extension JournalV2Repository {
    /// Read-only scope preview. No initialization, registration or deletion.
    func previewManagedHistory(now: Int64, matching session: JournalV2Session) throws -> ManagedHistoryScopePreview {
        let current = try revalidate(session, now: now)
        let directory = databaseURL.deletingLastPathComponent()
        let scope = try ManagedHistoryScopeReader.inspect(in: directory, session: current)
        _ = try revalidate(current, now: now)
        return scope
    }
}

extension JournalV2Repository {
    /// Only explicit initialization of an absent managed namespace. Caller
    /// owns the session lock. Never adopt a partially initialized directory.
    package func initializeManagedHistory(now: Int64, matching session: JournalV2Session) throws {
        let scope = try previewManagedHistory(now: now, matching: session)
        guard scope.state == .notInitialized else {
            throw ManagedHistoryPersistenceError.incompleteInventory
        }
        try ManagedHistoryBackupWriter.initializeEmpty(in: databaseURL.deletingLastPathComponent())
        _ = try revalidate(session, now: now)
    }

    package func createManagedHistoryBackup(now: Int64, matching session: JournalV2Session) throws {
        _ = try writeManagedBackup(now: now, matching: session)
        _ = try revalidate(session, now: now)
    }
}
