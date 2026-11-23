import CSQLite
import Foundation
import WorktimeDomain

/// Schema-2 live observation marker, scoped to exactly one committed Journal generation.
/// It does not prove actual attendance or authorize reuse of an earlier clock observation.
enum JournalV2CheckpointCodec {
    static func validate(
        _ marker: ObservationCheckpoint, catalog: WorkdayCatalog,
        lastEvent: Int64?, now: Int64
    ) throws {
        guard marker.version.revision > 0, catalog.activeID == marker.dayID,
              let lastEvent, marker.observedAt >= lastEvent,
              (-2_208_988_800 ... 253_402_300_799).contains(marker.observedAt),
              marker.observedAt <= now
        else { throw ObservationCheckpointError.invalid }
    }

    static func read(
        _ db: OpaquePointer, version: StoreVersion, catalog: WorkdayCatalog,
        lastEvent: Int64?, now: Int64
    ) throws -> ObservationCheckpoint? {
        try statement(db, """
        SELECT epoch, revision, day_id, observed_at
        FROM observation_checkpoint ORDER BY id
        """) { stmt in
            let status = sqlite3_step(stmt)
            guard status != SQLITE_DONE else { return nil }
            try check(status, expected: SQLITE_ROW)
            guard sqlite3_column_type(stmt, 0) == SQLITE_TEXT,
                  sqlite3_column_bytes(stmt, 0) == 36,
                  sqlite3_column_type(stmt, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(stmt, 2) == SQLITE_TEXT,
                  sqlite3_column_bytes(stmt, 2) == 36,
                  sqlite3_column_type(stmt, 3) == SQLITE_INTEGER,
                  let rawEpoch = sqlite3_column_text(stmt, 0),
                  let rawDay = sqlite3_column_text(stmt, 2),
                  let epoch = UUID(uuidString: String(cString: rawEpoch)),
                  let dayID = UUID(uuidString: String(cString: rawDay)),
                  String(cString: rawEpoch) == epoch.uuidString,
                  String(cString: rawDay) == dayID.uuidString
            else { throw ObservationCheckpointError.invalid }
            let marker = ObservationCheckpoint(
                version: StoreVersion(epoch: epoch, revision: sqlite3_column_int64(stmt, 1)),
                dayID: dayID, observedAt: sqlite3_column_int64(stmt, 3)
            )
            guard marker.version == version else { throw ObservationCheckpointError.invalid }
            try validate(marker, catalog: catalog, lastEvent: lastEvent, now: now)
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            return marker
        }
    }

    static func write(_ db: OpaquePointer, marker: ObservationCheckpoint) throws {
        try statement(db, """
        INSERT INTO observation_checkpoint (id, epoch, revision, day_id, observed_at)
        VALUES (1, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            epoch = excluded.epoch, revision = excluded.revision,
            day_id = excluded.day_id, observed_at = excluded.observed_at
        """) { stmt in
            try check(sqlite3_bind_text(stmt, 1, marker.version.epoch.uuidString, -1, transient))
            try check(sqlite3_bind_int64(stmt, 2, marker.version.revision))
            try check(sqlite3_bind_text(stmt, 3, marker.dayID.uuidString, -1, transient))
            try check(sqlite3_bind_int64(stmt, 4, marker.observedAt))
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            guard sqlite3_changes(db) == 1 else { throw SnapshotStoreError.invalidSnapshot }
        }
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func check(_ status: Int32, expected: Int32 = SQLITE_OK) throws {
        guard status == expected else { throw SnapshotStoreError.sqlite(status) }
    }

    private static func statement<T>(
        _ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var pointer: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &pointer, nil))
        guard let stmt = pointer else { throw SnapshotStoreError.invalidSnapshot }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }
}
