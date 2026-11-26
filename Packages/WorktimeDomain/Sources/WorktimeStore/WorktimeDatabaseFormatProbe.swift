import CSQLite
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum WorktimeDatabaseFormat: Sendable, Equatable {
    case missing, schemaOne, schemaTwo, unknown
}

/// Identifies an existing local database without opening a writable SQLite handle.
/// This is a routing decision only: schema=2 is not proof that its Journal is healthy.
/// The application must validate the complete Journal before enabling any actions.
public enum WorktimeDatabaseFormatProbe {
    public static func inspect(url: URL) throws -> WorktimeDatabaseFormat {
        let canonical = try DatabaseFileGuard.canonicalURL(url)
        var metadata = stat()
        if lstat(canonical.path, &metadata) != 0 {
            let code = errno
            if code == ENOENT {
                return .missing
            }
            throw DatabaseFileError.system(code)
        }
        let identity = try DatabaseFileGuard.preservationIdentity(canonical)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(canonical.path, &handle, flags, nil)
        defer { sqlite3_close(handle) }
        guard status == SQLITE_OK, let db = handle else {
            throw SnapshotStoreError.sqlite(status)
        }
        guard sqlite3_db_readonly(db, "main") == 1 else {
            throw DatabaseFileError.unsafeFile
        }
        guard sqlite3_exec(db, "PRAGMA trusted_schema = OFF", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK
        else { throw SnapshotStoreError.invalidSnapshot }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else {
            throw SnapshotStoreError.sqlite(prepared)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SnapshotStoreError.invalidSnapshot
        }
        let version = sqlite3_column_int64(statement, 0)
        guard try DatabaseFileGuard.preservationIdentity(canonical) == identity else {
            throw DatabaseFileError.unsafeFile
        }
        switch version {
        case 1: return .schemaOne
        case 2: return .schemaTwo
        default: return .unknown
        }
    }
}
