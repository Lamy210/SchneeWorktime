import CSQLite
import Foundation
import WorktimeDomain

/// Fresh-install schema-2 state. This is not an adapter for existing schema-1 files.
struct JournalV2LiveState {
    let version: StoreVersion
    let rows: [JournalEventRow]
    let catalog: WorkdayCatalog
}

enum JournalV2LiveWriteError: Error, Equatable {
    case committedButUnverified(StoreVersion)
}

/// A fresh-only schema-2 journal core. Application cutover and crash recovery are separate P0 work.
/// A caller must own the directory/session lock; no automatic schema migration or deletion occurs.
struct JournalV2LiveStore {
    private let url: URL
    private let fileIdentity: DatabaseFileGuard.Identity

    init(url: URL, createIfMissing: Bool = false) throws {
        let canonical = try DatabaseFileGuard.canonicalURL(url)
        self.url = canonical
        let created = try DatabaseFileGuard.prepare(canonical, createIfMissing: createIfMissing)
        try Self.connect(canonical, flags: SQLITE_OPEN_READWRITE) { db in
            if created {
                try Self.transaction(db) {
                    try Self.bootstrap(db)
                }
            } else {
                guard try Self.scalar(db, "PRAGMA user_version") == 2 else {
                    throw SnapshotStoreError.unsupportedSchema
                }
            }
            _ = try Self.read(db, now: Int64.max)
        }
        fileIdentity = try DatabaseFileGuard.preservationIdentity(canonical)
    }

    private static func bootstrap(_ db: OpaquePointer) throws {
        guard try scalar(db, "PRAGMA user_version") == 0,
              try scalar(db, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0
        else { throw SnapshotStoreError.unsupportedSchema }
        try execute(db, """
        CREATE TABLE live_generation (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            epoch TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision BETWEEN 0 AND 100000)
        ) STRICT;
        CREATE TABLE journal_event (
            sequence INTEGER PRIMARY KEY CHECK (sequence BETWEEN 1 AND 100000),
            payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 65536)
        ) STRICT;
        """)
        try execute(db, "INSERT INTO live_generation VALUES (1, '\(UUID().uuidString)', 0)")
        try execute(db, "PRAGMA user_version = 2")
    }

    /// Reopens and replays only a schema-2 live database; does not repair an invalid file.
    func load(now: Int64) throws -> JournalV2LiveState {
        guard try DatabaseFileGuard.preservationIdentity(url) == fileIdentity else {
            throw DatabaseFileError.unsafeFile
        }
        let result = try Self.connect(url, flags: SQLITE_OPEN_READONLY) { db in
            try Self.execute(db, "PRAGMA query_only = ON")
            return try Self.transactionRead(db) {
                try Self.read(db, now: now)
            }
        }
        guard try DatabaseFileGuard.preservationIdentity(url) == fileIdentity else {
            throw DatabaseFileError.unsafeFile
        }
        return result
    }

    /// One transaction, exact pre-state fence, and no blind retry after ambiguous COMMIT.
    func append(
        _ event: JournalEvent, matching expected: JournalV2LiveState, now: Int64
    ) throws -> JournalV2LiveState {
        let nextVersion = StoreVersion(
            epoch: expected.version.epoch, revision: expected.version.revision + 1
        )
        guard try DatabaseFileGuard.preservationIdentity(url) == fileIdentity else {
            throw DatabaseFileError.unsafeFile
        }
        let validated = try Self.connect(url, flags: SQLITE_OPEN_READWRITE) { db in
            try Self.transaction(db) {
                try Self.insertAppend(event, matching: expected, next: nextVersion, db: db, now: now)
            }
        }
        // COMMIT has already happened: a failed readback is an ambiguous outcome.
        do {
            let committed = try load(now: now)
            guard committed.version == nextVersion,
                  committed.rows == expected.rows + [validated.row],
                  committed.catalog == validated.catalog
            else { throw JournalMigrationError.verificationFailed }
            return committed
        } catch {
            throw JournalV2LiveWriteError.committedButUnverified(nextVersion)
        }
    }

    /// A logical reset, not secure erasure. Exact journal bytes and epoch are CAS-fenced.
    func reset(matching expected: JournalV2LiveState, now: Int64) throws -> JournalV2LiveState {
        let next = StoreVersion(epoch: UUID(), revision: 0)
        guard try DatabaseFileGuard.preservationIdentity(url) == fileIdentity else {
            throw DatabaseFileError.unsafeFile
        }
        try Self.connect(url, flags: SQLITE_OPEN_READWRITE) { db in
            try Self.transaction(db) {
                let current = try Self.read(db, now: now)
                guard current.version == expected.version else { throw SnapshotStoreError.staleVersion }
                guard current.rows == expected.rows, current.catalog == expected.catalog else {
                    throw JournalMigrationError.verificationFailed
                }
                try Self.execute(db, "DELETE FROM journal_event")
                try Self.statement(db, """
                UPDATE live_generation SET epoch = ?, revision = 0
                WHERE id = 1 AND epoch = ? AND revision = ?
                """) { stmt in
                    try Self.check(sqlite3_bind_text(stmt, 1, next.epoch.uuidString, -1, transient))
                    try Self.check(sqlite3_bind_text(
                        stmt, 2, current.version.epoch.uuidString, -1, transient
                    ))
                    try Self.check(sqlite3_bind_int64(stmt, 3, current.version.revision))
                    try Self.check(sqlite3_step(stmt), expected: SQLITE_DONE)
                    guard sqlite3_changes(db) == 1 else { throw SnapshotStoreError.staleVersion }
                }
            }
        }
        do {
            let committed = try load(now: now)
            guard committed.version == next, committed.rows.isEmpty,
                  committed.catalog == WorkdayCatalog()
            else { throw JournalMigrationError.verificationFailed }
            return committed
        } catch {
            throw JournalV2LiveWriteError.committedButUnverified(next)
        }
    }

    /// Only runs inside BEGIN IMMEDIATE; validation and CAS are committed together.
    private static func insertAppend(
        _ event: JournalEvent, matching expected: JournalV2LiveState,
        next: StoreVersion, db: OpaquePointer, now: Int64
    ) throws -> JournalStagingValidatedAppend {
        let current = try read(db, now: now)
        guard current.version == expected.version else { throw SnapshotStoreError.staleVersion }
        guard current.rows == expected.rows, current.catalog == expected.catalog else {
            throw JournalMigrationError.verificationFailed
        }
        guard current.version.revision < Int64(JournalRowCodec.maxRows) else {
            throw JournalMigrationError.rowLimit
        }
        let capacity = JournalCapacity(
            revision: current.version.revision, limit: Int64(JournalRowCodec.maxRows)
        )
        if case let .command(command, _) = event.action,
           command.opensWorkday, !capacity.canOpenWorkday
        {
            throw CatalogPersistenceError.insufficientStartCapacity
        }
        if current.catalog.activeID != nil, !capacity.allowsActiveMutation(event.action) {
            throw CatalogPersistenceError.reservedExitCapacity
        }
        let result = try JournalStagingAppendValidation.validate(
            event, rows: current.rows, catalog: current.catalog,
            expected: current.version, now: now
        )
        try statement(db, "INSERT INTO journal_event VALUES (?, ?)") { stmt in
            try check(sqlite3_bind_int64(stmt, 1, result.row.sequence))
            try bind(result.row.payload, at: 2, in: stmt)
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
        }
        try statement(db, """
        UPDATE live_generation SET revision = ?
        WHERE id = 1 AND epoch = ? AND revision = ?
        """) { stmt in
            try check(sqlite3_bind_int64(stmt, 1, next.revision))
            try check(sqlite3_bind_text(
                stmt, 2, current.version.epoch.uuidString, -1, transient
            ))
            try check(sqlite3_bind_int64(stmt, 3, current.version.revision))
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            guard sqlite3_changes(db) == 1 else { throw SnapshotStoreError.staleVersion }
        }
        return result
    }

    private static func read(_ db: OpaquePointer, now: Int64) throws -> JournalV2LiveState {
        guard try scalar(db, "PRAGMA user_version") == 2 else {
            throw SnapshotStoreError.unsupportedSchema
        }
        let version = try statement(
            db, "SELECT epoch, revision FROM live_generation WHERE id = 1"
        ) { stmt -> StoreVersion in
            try check(sqlite3_step(stmt), expected: SQLITE_ROW)
            guard sqlite3_column_type(stmt, 0) == SQLITE_TEXT,
                  let raw = sqlite3_column_text(stmt, 0),
                  let epoch = UUID(uuidString: String(cString: raw)),
                  String(cString: raw) == epoch.uuidString,
                  sqlite3_column_type(stmt, 1) == SQLITE_INTEGER
            else { throw SnapshotStoreError.invalidSnapshot }
            let revision = sqlite3_column_int64(stmt, 1)
            guard (0 ... Int64(JournalRowCodec.maxRows)).contains(revision) else {
                throw JournalMigrationError.rowLimit
            }
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            return StoreVersion(epoch: epoch, revision: revision)
        }
        let rows = try statement(
            db, "SELECT sequence, payload FROM journal_event ORDER BY sequence"
        ) { stmt -> [JournalEventRow] in
            var rows: [JournalEventRow] = []
            var remaining = JournalRowCodec.maxTotalBytes
            while Int64(rows.count) < version.revision {
                try check(sqlite3_step(stmt), expected: SQLITE_ROW)
                guard sqlite3_column_type(stmt, 0) == SQLITE_INTEGER,
                      sqlite3_column_int64(stmt, 0) == Int64(rows.count + 1),
                      sqlite3_column_type(stmt, 1) == SQLITE_BLOB
                else { throw JournalMigrationError.invalidSequence }
                let count = Int(sqlite3_column_bytes(stmt, 1))
                guard count > 0, count <= min(JournalRowCodec.maxRowBytes, remaining),
                      let bytes = sqlite3_column_blob(stmt, 1)
                else { throw JournalMigrationError.byteLimit }
                rows.append(JournalEventRow(
                    sequence: Int64(rows.count + 1), payload: Data(bytes: bytes, count: count)
                ))
                remaining -= count
            }
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            return rows
        }
        let catalog = try JournalRowCodec.replay(rows, revision: version.revision, now: now)
        return JournalV2LiveState(version: version, rows: rows, catalog: catalog)
    }

    private static func connect<T>(
        _ url: URL, flags: Int32, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let identity = try DatabaseFileGuard.identity(url)
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &pointer, flags | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close(pointer) }
        guard status == SQLITE_OK, let db = pointer else { throw SnapshotStoreError.sqlite(status) }
        guard try DatabaseFileGuard.identity(url) == identity else { throw DatabaseFileError.unsafeFile }
        try check(sqlite3_busy_timeout(db, 5000))
        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 17 * 1024 * 1024)
        try execute(db, "PRAGMA trusted_schema = OFF")
        if flags == SQLITE_OPEN_READWRITE {
            try execute(db, "PRAGMA synchronous = FULL")
        }
        return try body(db)
    }

    private static func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute(db, "COMMIT")
            return value
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private static func transactionRead<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN")
        do {
            let value = try body()
            try execute(db, "COMMIT")
            return value
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        try statement(db, sql) { stmt in
            try check(sqlite3_step(stmt), expected: SQLITE_ROW)
            return sqlite3_column_int64(stmt, 0)
        }
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

    private static func bind(_ data: Data, at index: Int32, in stmt: OpaquePointer) throws {
        try data.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(bytes.count), transient))
        }
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private static func check(_ status: Int32, expected: Int32 = SQLITE_OK) throws {
        guard status == expected else { throw SnapshotStoreError.sqlite(status) }
    }
}
