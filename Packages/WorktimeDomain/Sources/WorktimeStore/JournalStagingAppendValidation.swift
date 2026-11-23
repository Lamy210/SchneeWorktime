import Foundation
import WorktimeDomain

/// Validate an offline append against a pinned pre-append event history.
/// Pure validation: no SQLite writes and no retry/adoption authorization.
enum JournalStagingAppendValidation {
    static func row(
        for event: JournalEvent, rows: [JournalEventRow], catalog: WorkdayCatalog,
        expected: StoreVersion, now: Int64
    ) throws -> JournalEventRow {
        guard event.now <= now else { throw CatalogPersistenceError.futureEvent }
        guard expected.revision >= 0,
              expected.revision < Int64(JournalRowCodec.maxRows),
              Int64(rows.count) == expected.revision
        else { throw JournalMigrationError.invalidSequence }
        if let last = rows.last {
            let previous = try JSONDecoder().decode(JournalEvent.self, from: last.payload)
            guard event.now >= previous.now else { throw JournalMigrationError.invalidEvent }
        }

        let row = try JournalRowCodec.encode(event, sequence: expected.revision + 1)
        var nextCatalog = catalog
        let previousReviewVersion = nextCatalog.reviewVersion
        try event.apply(to: &nextCatalog)
        guard nextCatalog.reviewVersion != previousReviewVersion else {
            throw JournalMigrationError.invalidEvent
        }
        guard try JournalRowCodec.replay(
            rows + [row], revision: expected.revision + 1, now: now
        ) == nextCatalog else { throw JournalMigrationError.verificationFailed }
        return row
    }
}
