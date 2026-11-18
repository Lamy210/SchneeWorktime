import Foundation
import WorktimeDomain

public enum CatalogPersistenceError: Error, Equatable {
    case unsupportedSchema, invalidJournal, futureEvent, eventLimit, insufficientStartCapacity
}

public struct CatalogSession: Sendable {
    public let version: StoreVersion
    public let catalog: WorkdayCatalog
    let validatedSnapshot: StoredSnapshot
    let validatedAt: Int64

    init(snapshot: StoredSnapshot, catalog: WorkdayCatalog, now: Int64) {
        version = snapshot.version
        self.catalog = catalog
        validatedSnapshot = snapshot
        validatedAt = now
    }

    public func previewReview(
        dayID: UUID, selection: ObservationGap, classification: ReviewClassification, now: Int64
    ) throws -> StoredReviewPreview {
        let preview = try catalog.previewReview(dayID: dayID, selection: selection,
                                                classification: classification, now: now)
        return StoredReviewPreview(version: version, preview: preview)
    }
}

public struct StoredReviewPreview: Sendable {
    public let version: StoreVersion
    public let preview: CatalogReviewPreview
}

struct LoadedCatalog {
    let session: CatalogSession
    var journal: CatalogJournal
}

/// Reconstruct canonical state by replaying validated domain operations.
/// A durable store version fences each mutation, including history reviews.
public struct CatalogRepository: Sendable {
    private let store: SnapshotStore

    public init(url: URL, createIfMissing: Bool = false) throws {
        store = try SnapshotStore(url: url, createIfMissing: createIfMissing)
    }

    public func load(now: Int64) throws -> CatalogSession {
        try read(now: now).session
    }

    /// Reuse only an exact byte-for-byte validated snapshot. Revision equality alone is insufficient.
    public func revalidate(_ cached: CatalogSession, now: Int64) throws -> CatalogSession {
        let current = try store.load()
        guard current.version == cached.version else { throw SnapshotStoreError.staleVersion }
        guard current == cached.validatedSnapshot else { throw CatalogPersistenceError.invalidJournal }
        if now < cached.validatedAt {
            return try CatalogBackup.validateSnapshot(current, now: now)
        }
        return cached
    }

    /// Capture one committed snapshot, validate journal replay, then encode without writing to storage.
    public func makeBackup(now: Int64, expected: StoreVersion) throws -> Data {
        let snapshot = try store.load()
        guard snapshot.version == expected else { throw SnapshotStoreError.staleVersion }
        return try CatalogBackup.encode(snapshot, now: now)
    }

    public func apply(
        _ command: WorkdayCommand, at instant: Int64, now: Int64, expected: StoreVersion
    ) throws -> CatalogSession {
        let event = JournalEvent(action: .command(JournalCommand(command), at: instant), now: now)
        return try mutate(event, expected: expected)
    }

    public func setFutureRest(
        dayID: UUID, remainingSeconds: Int64?, now: Int64, expected: StoreVersion
    ) throws -> CatalogSession {
        let action = JournalAction.futureRest(dayID: dayID, remainingSeconds: remainingSeconds)
        return try mutate(JournalEvent(action: action, now: now), expected: expected)
    }

    public func recordObservation(
        dayID: UUID, gap: ObservationGap, now: Int64, expected: StoreVersion
    ) throws -> CatalogSession {
        let action = JournalAction.observation(dayID: dayID, start: gap.start, end: gap.end)
        return try mutate(JournalEvent(action: action, now: now), expected: expected)
    }

    public func setDesiredDeparture(
        dayID: UUID, candidate: Int64?, warningAcknowledged: Bool, now: Int64, expected: StoreVersion
    ) throws -> CatalogSession {
        let action = JournalAction.desiredDeparture(
            dayID: dayID, candidate: candidate, warningAcknowledged: warningAcknowledged
        )
        return try mutate(JournalEvent(action: action, now: now), expected: expected)
    }

    public func commitReview(
        _ proposal: StoredReviewPreview, now: Int64
    ) throws -> CatalogSession {
        let preview = proposal.preview
        let selection = preview.review.selection
        let classification = JournalClassification(preview.review.classification)
        let action = JournalAction.review(dayID: preview.dayID, start: selection.start,
                                          end: selection.end, classification: classification)
        let event = JournalEvent(action: action, now: now)
        var loaded = try read(now: now)
        guard loaded.session.version == proposal.version else { throw SnapshotStoreError.staleVersion }
        var catalog = loaded.session.catalog
        try catalog.commitReview(preview, now: now)
        return try commit(event, catalog: catalog, loaded: &loaded)
    }

    public func loadObservationCheckpoint(expected: StoreVersion) throws -> ObservationCheckpoint? {
        try store.loadObservationCheckpoint(expected: expected)
    }

    public func saveObservationCheckpoint(dayID: UUID, observedAt: Int64, expected: StoreVersion) throws {
        try store.saveObservationCheckpoint(dayID: dayID, observedAt: observedAt, expected: expected)
    }

    private func mutate(_ event: JournalEvent, expected: StoreVersion) throws -> CatalogSession {
        var loaded = try read(now: event.now)
        guard loaded.session.version == expected else { throw SnapshotStoreError.staleVersion }
        let canOpenWorkday = loaded.session.journalCapacity.canOpenWorkday
        if case let .command(command, _) = event.action, command.opensWorkday, !canOpenWorkday {
            throw CatalogPersistenceError.insufficientStartCapacity
        }
        var catalog = loaded.session.catalog
        try event.apply(to: &catalog)
        if catalog == loaded.session.catalog {
            return loaded.session
        }
        return try commit(event, catalog: catalog, loaded: &loaded)
    }

    private func read(now: Int64) throws -> LoadedCatalog {
        let stored = try store.load()
        let journal: CatalogJournal
        if let payload = stored.payload {
            do {
                journal = try JSONDecoder().decode(CatalogJournal.self, from: payload)
            } catch {
                throw CatalogPersistenceError.invalidJournal
            }
        } else {
            journal = CatalogJournal()
        }
        guard Int64(journal.events.count) == stored.version.revision else {
            throw CatalogPersistenceError.invalidJournal
        }
        let catalog = try journal.replay(now: now)
        return LoadedCatalog(session: CatalogSession(snapshot: stored, catalog: catalog, now: now), journal: journal)
    }

    private func commit(
        _ event: JournalEvent, catalog: WorkdayCatalog, loaded: inout LoadedCatalog
    ) throws -> CatalogSession {
        guard loaded.journal.events.count < CatalogJournal.maxEvents else {
            throw CatalogPersistenceError.eventLimit
        }
        loaded.journal.events.append(event)
        let payload = try JSONEncoder().encode(loaded.journal)
        let version = try store.save(payload, expected: loaded.session.version)
        let snapshot = StoredSnapshot(version: version, payload: payload)
        return CatalogSession(snapshot: snapshot, catalog: catalog, now: event.now)
    }
}

public extension CatalogRepository {
    /// Read a bounded private archive once; confirmation uses the captured bytes.
    func previewRollback(file: URL, now: Int64, expected: StoreVersion) throws -> CatalogRollbackProposal {
        try previewRollback(from: BackupFile.load(file), now: now, expected: expected)
    }

    /// No writes or files are created during preview.
    func previewRollback(from data: Data, now: Int64, expected: StoreVersion) throws -> CatalogRollbackProposal {
        let current = try store.load()
        guard current.version == expected else { throw SnapshotStoreError.staleVersion }
        let decoded = try CatalogBackup.decodeValidated(data, now: now)
        return try Self.rollbackProposal(source: decoded.snapshot, current: current, now: now)
    }

    /// Caller must explicitly confirm the preview, select a fresh private preservation path,
    /// and stop all application writers/notifications before calling. Reopen the controller afterwards.
    func commitRollback(
        _ proposal: CatalogRollbackProposal, preserveCurrentAt destination: URL, now: Int64
    ) throws -> CatalogSession {
        let current = try store.load()
        guard current.version == proposal.currentVersion else { throw SnapshotStoreError.staleVersion }
        _ = try Self.rollbackProposal(source: proposal.source, current: current, now: now)
        let original = try CatalogBackup.encode(current, now: now)
        try BackupFile.publish(original, to: destination)
        guard try BackupFile.load(destination) == original else { throw CatalogRollbackError.preservationFailed }
        let version = try store.replaceForRecovery(proposal.source, expected: current.version)
        return try CatalogBackup.validateSnapshot(
            StoredSnapshot(version: version, payload: proposal.source.payload), now: now
        )
    }

    private static func rollbackProposal(
        source: StoredSnapshot, current: StoredSnapshot, now: Int64
    ) throws -> CatalogRollbackProposal {
        guard source.version.epoch == current.version.epoch else { throw CatalogRollbackError.differentGeneration }
        guard source.version.revision > 0, source.version.revision < current.version.revision,
              let sourcePayload = source.payload, let currentPayload = current.payload
        else { throw CatalogRollbackError.notEarlier }
        let original = try CatalogBackup.validateSnapshot(current, now: now)
        let restored = try CatalogBackup.validateSnapshot(source, now: now)
        guard original.catalog.activeID == nil, restored.catalog.activeID == nil else {
            throw CatalogRollbackError.activeWorkday
        }
        let decoder = JSONDecoder()
        let previous = try decoder.decode(CatalogJournal.self, from: sourcePayload)
        let latest = try decoder.decode(CatalogJournal.self, from: currentPayload)
        guard latest.events.prefix(previous.events.count).elementsEqual(previous.events) else {
            throw CatalogRollbackError.divergentHistory
        }
        return CatalogRollbackProposal(
            source: source, currentVersion: current.version,
            currentDays: original.catalog.days.count, restoredDays: restored.catalog.days.count
        )
    }
}

public struct CatalogResetProposal: Sendable {
    public let version: StoreVersion
    public let workdays: Int
    public let corrections: Int
    public let hasActiveWorkday: Bool
    fileprivate let source: StoredSnapshot
}

public extension CatalogRepository {
    /// Read-only deletion preview of one validated catalog. No backup or external file is changed.
    func previewReset(now: Int64, expected: StoreVersion) throws -> CatalogResetProposal {
        let current = try load(now: now)
        guard current.version == expected else { throw SnapshotStoreError.staleVersion }
        return CatalogResetProposal(
            version: current.version, workdays: current.catalog.days.count,
            corrections: current.catalog.reviewAudit.count, hasActiveWorkday: current.catalog.activeID != nil,
            source: current.validatedSnapshot
        )
    }

    /// Caller must obtain explicit confirmation and stop application writers and owned notifications.
    /// This resets live logical records, not filesystem remnants or backup/export files.
    func commitReset(_ proposal: CatalogResetProposal, now: Int64) throws -> CatalogSession {
        let current = try load(now: now)
        guard current.version == proposal.version else { throw SnapshotStoreError.staleVersion }
        guard current.validatedSnapshot == proposal.source else { throw CatalogPersistenceError.invalidJournal }
        let version = try store.reset(expected: proposal.version, matching: proposal.source)
        return try CatalogBackup.validateSnapshot(StoredSnapshot(version: version, payload: nil), now: now)
    }
}
