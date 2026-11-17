import Foundation
import WorktimeDomain

public enum CatalogPersistenceError: Error, Equatable {
    case unsupportedSchema, invalidJournal, futureEvent, eventLimit
}

public struct CatalogSession: Sendable {
    public let version: StoreVersion
    public let catalog: WorkdayCatalog

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

    public func apply(
        _ command: WorkdayCommand, at instant: Int64, now: Int64, expected: StoreVersion
    ) throws -> CatalogSession {
        let event = JournalEvent(action: .command(JournalCommand(command), at: instant), now: now)
        return try mutate(event, expected: expected)
    }

    public func recordObservation(
        dayID: UUID, gap: ObservationGap, now: Int64, expected: StoreVersion
    ) throws -> CatalogSession {
        let action = JournalAction.observation(dayID: dayID, start: gap.start, end: gap.end)
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

    private func mutate(_ event: JournalEvent, expected: StoreVersion) throws -> CatalogSession {
        var loaded = try read(now: event.now)
        guard loaded.session.version == expected else { throw SnapshotStoreError.staleVersion }
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
        return LoadedCatalog(session: CatalogSession(version: stored.version, catalog: catalog), journal: journal)
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
        return CatalogSession(version: version, catalog: catalog)
    }
}
