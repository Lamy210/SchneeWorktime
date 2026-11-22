import Foundation
import WorktimeDomain

/// A proposed schema-2 row, not a live database row or a persistence authorization.
struct JournalEventRow: Equatable {
    let sequence: Int64
    let payload: Data
}

enum JournalMigrationError: Error, Equatable {
    case invalidSequence, invalidEvent, rowLimit, byteLimit, verificationFailed
}

/// Bounded staging codec. A future SQLite adapter must enforce these limits before allocating input.
/// The current schema-1 repository cannot adopt these rows.
enum JournalRowCodec {
    static let maxRows = 100_000
    static let maxRowBytes = 65536
    static let maxTotalBytes = 64 * 1024 * 1024

    static func encode(_ event: JournalEvent, sequence: Int64) throws -> JournalEventRow {
        guard sequence > 0 else { throw JournalMigrationError.invalidSequence }
        // Stable bytes are required when an uncertain append is inspected again.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        guard !data.isEmpty, data.count <= maxRowBytes else { throw JournalMigrationError.byteLimit }
        return JournalEventRow(sequence: sequence, payload: data)
    }

    static func decode(_ rows: [JournalEventRow], revision: Int64) throws -> [JournalEvent] {
        guard rows.count <= maxRows else { throw JournalMigrationError.rowLimit }
        guard revision == Int64(rows.count) else { throw JournalMigrationError.invalidSequence }
        var total = 0
        var events: [JournalEvent] = []
        events.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard row.sequence == Int64(index + 1) else { throw JournalMigrationError.invalidSequence }
            guard !row.payload.isEmpty, row.payload.count <= maxRowBytes,
                  row.payload.count <= maxTotalBytes - total else { throw JournalMigrationError.byteLimit }
            total += row.payload.count
            do {
                let event = try JSONDecoder().decode(JournalEvent.self, from: row.payload)
                events.append(event)
            } catch {
                throw JournalMigrationError.invalidEvent
            }
        }
        return events
    }

    static func replay(_ rows: [JournalEventRow], revision: Int64, now: Int64) throws -> WorkdayCatalog {
        let events = try decode(rows, revision: revision)
        var catalog = WorkdayCatalog()
        for event in events {
            guard event.now <= now else { throw CatalogPersistenceError.futureEvent }
            let previous = catalog.reviewVersion
            try event.apply(to: &catalog)
            guard catalog.reviewVersion != previous else { throw CatalogPersistenceError.invalidJournal }
        }
        return catalog
    }
}

/// Preserve exact legacy bytes and validate the typed event sequence and catalog before staging.
/// No database is created; a new epoch and all rows are only an in-memory candidate.
struct JournalMigrationDraft {
    let source: StoredSnapshot
    let candidateVersion: StoreVersion
    let rows: [JournalEventRow]

    init(source: StoredSnapshot, now: Int64) throws {
        let original = try CatalogBackup.validateSnapshot(source, now: now)
        let journal = if let payload = source.payload {
            try JSONDecoder().decode(CatalogJournal.self, from: payload)
        } else {
            CatalogJournal()
        }
        let staged = try journal.events.enumerated().map { index, event in
            try JournalRowCodec.encode(event, sequence: Int64(index + 1))
        }
        let revision = source.version.revision
        guard try JournalRowCodec.decode(staged, revision: revision) == journal.events,
              try JournalRowCodec.replay(staged, revision: revision, now: now) == original.catalog
        else { throw JournalMigrationError.verificationFailed }
        self.source = source
        candidateVersion = StoreVersion(epoch: UUID(), revision: revision)
        rows = staged
    }
}
