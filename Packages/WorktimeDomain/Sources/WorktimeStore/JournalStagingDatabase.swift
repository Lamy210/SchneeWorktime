import CSQLite
import Foundation
import WorktimeDomain

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Offline staging only. No live database path or adoption operation is accepted.
struct JournalStagingCandidate {
    let url: URL
    let draft: JournalMigrationDraft
}

enum JournalStagingDatabase {
    static func create(source: StoredSnapshot, in directory: URL, now: Int64) throws -> JournalStagingCandidate {
        let draft = try JournalMigrationDraft(source: source, now: now)
        var info = stat()
        guard directory.isFileURL, lstat(directory.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else { throw RecoveryCandidateError.unsafeDirectory }
        let staging = directory.appendingPathComponent("journal-v2-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw RecoveryCandidateError.system(errno) }
        let url = staging.appendingPathComponent("candidate.sqlite")
        guard try DatabaseFileGuard.prepare(url, createIfMissing: true) else {
            throw DatabaseFileError.unsafeFile
        }
        try connect(url, flags: SQLITE_OPEN_READWRITE) { db in
            try execute(db, "PRAGMA synchronous = FULL")
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try createSchema(db)
                try insertMetadata(db, draft: draft)
                try insertRows(db, rows: draft.rows)
                try execute(db, "PRAGMA user_version = 2")
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
        try verify(url, draft: draft, now: now)
        return JournalStagingCandidate(url: url, draft: draft)
    }

    /// Reopen independently and require exact agreement with the original in-memory draft.
    static func verify(_ url: URL, draft: JournalMigrationDraft, now: Int64) throws {
        let inspected = try inspect(url, now: now)
        guard inspected.source == draft.source, inspected.version == draft.candidateVersion,
              inspected.rows == draft.rows
        else { throw JournalMigrationError.verificationFailed }
    }

    /// Inspect an offline candidate without an in-memory draft. This does not authorize adoption.
    static func inspect(_ source: URL, now: Int64) throws -> JournalStagingInspection {
        let url = try DatabaseFileGuard.canonicalURL(source)
        let identity = try DatabaseFileGuard.preservationIdentity(url)
        let result = try connect(url, flags: SQLITE_OPEN_READONLY) { db in
            try execute(db, "PRAGMA query_only = ON")
            try execute(db, "BEGIN")
            try statement(db, "PRAGMA user_version") { stmt in
                try check(sqlite3_step(stmt), expected: SQLITE_ROW)
                guard sqlite3_column_int64(stmt, 0) == 2 else {
                    throw SnapshotStoreError.unsupportedSchema
                }
            }
            let metadata = try readMetadata(db)
            let rows = try readRows(db, revision: metadata.source.version.revision)
            let inspected = try JournalStagingInspection(
                source: metadata.source, version: metadata.version, rows: rows, now: now
            )
            try execute(db, "COMMIT")
            return inspected
        }
        guard try DatabaseFileGuard.preservationIdentity(url) == identity else {
            throw DatabaseFileError.unsafeFile
        }
        return result
    }

    private static func createSchema(_ db: OpaquePointer) throws {
        try execute(db, """
        CREATE TABLE migration_source (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            source_epoch TEXT NOT NULL,
            candidate_epoch TEXT NOT NULL CHECK (candidate_epoch <> source_epoch),
            revision INTEGER NOT NULL CHECK (revision BETWEEN 0 AND 10000),
            payload BLOB,
            CHECK ((revision = 0 AND payload IS NULL) OR (revision > 0 AND payload IS NOT NULL))
        ) STRICT;
        CREATE TABLE journal_event (
            sequence INTEGER PRIMARY KEY CHECK (sequence BETWEEN 1 AND 100000),
            payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 65536)
        ) STRICT;
        """)
    }

    private static func insertMetadata(_ db: OpaquePointer, draft: JournalMigrationDraft) throws {
        try statement(db, "INSERT INTO migration_source VALUES (1, ?, ?, ?, ?)") { stmt in
            try check(sqlite3_bind_text(stmt, 1, draft.source.version.epoch.uuidString, -1, transient))
            try check(sqlite3_bind_text(stmt, 2, draft.candidateVersion.epoch.uuidString, -1, transient))
            try check(sqlite3_bind_int64(stmt, 3, draft.source.version.revision))
            if let payload = draft.source.payload {
                try bind(payload, to: stmt, index: 4)
            } else {
                try check(sqlite3_bind_null(stmt, 4))
            }
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
        }
    }

    private static func insertRows(_ db: OpaquePointer, rows: [JournalEventRow]) throws {
        try statement(db, "INSERT INTO journal_event VALUES (?, ?)") { stmt in
            for row in rows {
                try check(sqlite3_bind_int64(stmt, 1, row.sequence))
                try bind(row.payload, to: stmt, index: 2)
                try check(sqlite3_step(stmt), expected: SQLITE_DONE)
                try check(sqlite3_reset(stmt))
                try check(sqlite3_clear_bindings(stmt))
            }
        }
    }

    private static func readMetadata(_ db: OpaquePointer) throws -> (source: StoredSnapshot, version: StoreVersion) {
        let sql = "SELECT id, source_epoch, candidate_epoch, revision, payload FROM migration_source ORDER BY id"
        return try statement(db, sql) { stmt in
            try check(sqlite3_step(stmt), expected: SQLITE_ROW)
            guard sqlite3_column_type(stmt, 0) == SQLITE_INTEGER, sqlite3_column_int64(stmt, 0) == 1,
                  sqlite3_column_type(stmt, 1) == SQLITE_TEXT, sqlite3_column_type(stmt, 2) == SQLITE_TEXT,
                  let source = sqlite3_column_text(stmt, 1), let candidate = sqlite3_column_text(stmt, 2),
                  let sourceEpoch = UUID(uuidString: String(cString: source)),
                  let candidateEpoch = UUID(uuidString: String(cString: candidate)), sourceEpoch != candidateEpoch,
                  sqlite3_column_type(stmt, 3) == SQLITE_INTEGER
            else { throw JournalMigrationError.verificationFailed }
            let revision = sqlite3_column_int64(stmt, 3)
            guard (0 ... Int64(CatalogJournal.maxEvents)).contains(revision) else {
                throw JournalMigrationError.invalidSequence
            }
            let payload: Data? = if revision == 0, sqlite3_column_type(stmt, 4) == SQLITE_NULL {
                nil
            } else {
                try readPayload(stmt, index: 4, limit: 16 * 1024 * 1024)
            }
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            return (
                StoredSnapshot(version: .init(epoch: sourceEpoch, revision: revision), payload: payload),
                StoreVersion(epoch: candidateEpoch, revision: revision)
            )
        }
    }

    private static func readRows(_ db: OpaquePointer, revision: Int64) throws -> [JournalEventRow] {
        try statement(db, "SELECT sequence, payload FROM journal_event ORDER BY sequence") { stmt in
            var rows: [JournalEventRow] = []
            var remainingBytes = JournalRowCodec.maxTotalBytes
            while Int64(rows.count) < revision {
                try check(sqlite3_step(stmt), expected: SQLITE_ROW)
                let sequence = Int64(rows.count + 1)
                guard sqlite3_column_type(stmt, 0) == SQLITE_INTEGER,
                      sqlite3_column_int64(stmt, 0) == sequence
                else { throw JournalMigrationError.invalidSequence }
                let payload = try readPayload(stmt, index: 1, limit: min(JournalRowCodec.maxRowBytes, remainingBytes))
                remainingBytes -= payload.count
                rows.append(JournalEventRow(sequence: sequence, payload: payload))
            }
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            return rows
        }
    }

    private static func readPayload(_ stmt: OpaquePointer, index: Int32, limit: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard sqlite3_column_type(stmt, index) == SQLITE_BLOB, count > 0, count <= limit,
              let bytes = sqlite3_column_blob(stmt, index)
        else { throw JournalMigrationError.byteLimit }
        return Data(bytes: bytes, count: count)
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func bind(_ data: Data, to stmt: OpaquePointer, index: Int32) throws {
        try data.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(bytes.count), transient))
        }
    }

    private static func connect<T>(
        _ url: URL, flags: Int32, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let identity = try DatabaseFileGuard.identity(url)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close(handle) }
        guard status == SQLITE_OK, let db = handle else { throw SnapshotStoreError.sqlite(status) }
        guard try DatabaseFileGuard.identity(url) == identity else { throw DatabaseFileError.unsafeFile }
        try check(sqlite3_busy_timeout(db, 5000))
        // Bound each SQLite value before decoding or copying into Swift-owned memory.
        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 17 * 1024 * 1024)
        try execute(db, "PRAGMA trusted_schema = OFF")
        return try body(db)
    }

    private static func check(_ status: Int32, expected: Int32 = SQLITE_OK) throws {
        guard status == expected else { throw SnapshotStoreError.sqlite(status) }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
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
