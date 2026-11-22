import CSQLite
import Foundation

/// An immutable migration anchor. This is *not* a live checkpoint in the candidate generation.
enum JournalCheckpointAnchor: Equatable {
    case unbound
    case absent
    case recorded(ObservationCheckpoint)

    static func captured(_ marker: ObservationCheckpoint?) -> JournalCheckpointAnchor {
        if let marker {
            return .recorded(marker)
        }
        return .absent
    }

    func validate(expected: StoreVersion, now: Int64) throws {
        guard case let .recorded(marker) = self else { return }
        guard marker.version == expected, expected.revision > 0,
              (-2_208_988_800 ... 253_402_300_799).contains(marker.observedAt),
              marker.observedAt <= now
        else { throw JournalMigrationError.verificationFailed }
    }

    static func write(
        _ anchor: JournalCheckpointAnchor, expected: StoreVersion, into db: OpaquePointer
    ) throws {
        guard anchor != .unbound else { return }
        try check(sqlite3_exec(db, """
        CREATE TABLE source_checkpoint (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            source_epoch TEXT NOT NULL,
            source_revision INTEGER NOT NULL,
            day_id TEXT,
            observed_at INTEGER,
            CHECK ((day_id IS NULL AND observed_at IS NULL) OR
                   (day_id IS NOT NULL AND observed_at IS NOT NULL))
        ) STRICT
        """, nil, nil, nil))
        try statement(db, "INSERT INTO source_checkpoint VALUES (1, ?, ?, ?, ?)") { stmt in
            try check(sqlite3_bind_text(stmt, 1, expected.epoch.uuidString, -1, transient))
            try check(sqlite3_bind_int64(stmt, 2, expected.revision))
            switch anchor {
            case .unbound:
                throw JournalMigrationError.verificationFailed
            case .absent:
                try check(sqlite3_bind_null(stmt, 3))
                try check(sqlite3_bind_null(stmt, 4))
            case let .recorded(marker):
                try check(sqlite3_bind_text(stmt, 3, marker.dayID.uuidString, -1, transient))
                try check(sqlite3_bind_int64(stmt, 4, marker.observedAt))
            }
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
        }
    }

    static func read(
        from db: OpaquePointer, expected: StoreVersion, now: Int64
    ) throws -> JournalCheckpointAnchor {
        let sql = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'source_checkpoint'"
        let exists = try statement(db, sql) { stmt in
            try check(sqlite3_step(stmt), expected: SQLITE_ROW)
            return sqlite3_column_int64(stmt, 0) == 1
        }
        guard exists else { return .unbound }
        let select = "SELECT source_epoch, source_revision, day_id, observed_at FROM source_checkpoint WHERE id = 1"
        return try statement(db, select) { stmt in
            try check(sqlite3_step(stmt), expected: SQLITE_ROW)
            guard sqlite3_column_type(stmt, 0) == SQLITE_TEXT,
                  sqlite3_column_bytes(stmt, 0) == 36,
                  let raw = sqlite3_column_text(stmt, 0),
                  String(cString: raw) == expected.epoch.uuidString,
                  sqlite3_column_type(stmt, 1) == SQLITE_INTEGER,
                  sqlite3_column_int64(stmt, 1) == expected.revision
            else { throw JournalMigrationError.verificationFailed }
            let anchor = try parseMarker(stmt, expected: expected, now: now)
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            return anchor
        }
    }

    private static func parseMarker(
        _ stmt: OpaquePointer, expected: StoreVersion, now: Int64
    ) throws -> JournalCheckpointAnchor {
        let missingDay = sqlite3_column_type(stmt, 2) == SQLITE_NULL
        let missingTime = sqlite3_column_type(stmt, 3) == SQLITE_NULL
        if missingDay && missingTime {
            return .absent
        }
        guard sqlite3_column_type(stmt, 2) == SQLITE_TEXT,
              sqlite3_column_bytes(stmt, 2) == 36,
              sqlite3_column_type(stmt, 3) == SQLITE_INTEGER,
              let raw = sqlite3_column_text(stmt, 2),
              let dayID = UUID(uuidString: String(cString: raw)),
              String(cString: raw) == dayID.uuidString
        else { throw JournalMigrationError.verificationFailed }
        let marker = ObservationCheckpoint(
            version: expected, dayID: dayID, observedAt: sqlite3_column_int64(stmt, 3)
        )
        let anchor = JournalCheckpointAnchor.recorded(marker)
        try anchor.validate(expected: expected, now: now)
        return anchor
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
        var prepared: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &prepared, nil))
        guard let stmt = prepared else { throw SnapshotStoreError.invalidSnapshot }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }
}
