import Foundation
import WorktimeDomain

/// Self-consistency of an offline candidate is not authenticity or permission to adopt it.
struct JournalStagingInspection {
    let source: StoredSnapshot
    let version: StoreVersion
    let rows: [JournalEventRow]
    let catalog: WorkdayCatalog

    init(source: StoredSnapshot, version: StoreVersion, rows: [JournalEventRow], now: Int64) throws {
        guard source.version.epoch != version.epoch,
              source.version.revision <= version.revision,
              version.revision <= Int64(JournalRowCodec.maxRows)
        else {
            throw JournalMigrationError.verificationFailed
        }
        let original = try CatalogBackup.validateSnapshot(source, now: now)
        let journal = if let payload = source.payload {
            try JSONDecoder().decode(CatalogJournal.self, from: payload)
        } else {
            CatalogJournal()
        }
        let events = try JournalRowCodec.decode(rows, revision: version.revision)
        guard Array(events.prefix(journal.events.count)) == journal.events else {
            throw JournalMigrationError.verificationFailed
        }
        let sourceRows = Array(rows.prefix(journal.events.count))
        let sourceReplay = try JournalRowCodec.replay(sourceRows, revision: source.version.revision, now: now)
        guard sourceReplay == original.catalog else { throw JournalMigrationError.verificationFailed }
        let replay = try JournalRowCodec.replay(rows, revision: version.revision, now: now)
        self.source = source
        self.version = version
        self.rows = rows
        catalog = replay
    }
}
