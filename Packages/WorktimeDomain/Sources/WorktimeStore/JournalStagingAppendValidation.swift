import Foundation
import WorktimeDomain

/// A checked next row and catalog state; no SQLite write has occurred.
struct JournalStagingValidatedAppend {
    let row: JournalEventRow
    let catalog: WorkdayCatalog
}

/// Validate an offline append against a pinned pre-append event history.
/// Pure validation: no SQLite writes and no retry/adoption authorization.
enum JournalStagingAppendValidation {
    static func validate(
        _ event: JournalEvent, rows: [JournalEventRow], catalog: WorkdayCatalog,
        expected: StoreVersion, now: Int64
    ) throws -> JournalStagingValidatedAppend {
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
        return JournalStagingValidatedAppend(row: row, catalog: nextCatalog)
    }
}
