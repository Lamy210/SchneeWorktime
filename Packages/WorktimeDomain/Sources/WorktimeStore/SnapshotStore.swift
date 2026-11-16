import CSQLite
import Foundation

public enum SnapshotStoreError: Error, Equatable {
    case sqlite(Int32), invalidSnapshot, unsupportedSchema, staleVersion, revisionOverflow, invalidPayload
}

public struct StoreVersion: Sendable, Equatable {
    public let epoch: UUID
    public let revision: Int64
}

public struct StoredSnapshot: Sendable, Equatable {
    public let version: StoreVersion
    public let payload: Data?
}

/// A single SQLite row, not a catalog codec or backup/restore system.
/// Only a trusted application coordinator may encode and submit canonical data.
public struct SnapshotStore: Sendable {
    private let url: URL
    private static let maxPayload = 16 * 1024 * 1024

    public init(url: URL, createIfMissing: Bool = false) throws {
        self.url = url
        let create = createIfMissing && !FileManager.default.fileExists(atPath: url.path)
        try connection(create: create) { db in
            try Self.transaction(db) {
                let schema = try Self.scalar(db, "PRAGMA user_version")
                if schema == 0, create {
                    let sql = "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
                    let tables = try Self.scalar(db, sql)
                    guard tables == 0 else { throw SnapshotStoreError.unsupportedSchema }
                    try Self.execute(db, """
                    CREATE TABLE snapshot (
                        id INTEGER PRIMARY KEY CHECK (id = 1),
                        epoch TEXT NOT NULL,
                        revision INTEGER NOT NULL CHECK (revision >= 0),
                        payload BLOB,
                        CHECK ((revision = 0 AND payload IS NULL) OR (revision > 0 AND payload IS NOT NULL))
                    ) STRICT
                    """)
                    try Self.execute(db, "INSERT INTO snapshot VALUES (1, '\(UUID().uuidString)', 0, NULL)")
                    try Self.execute(db, "PRAGMA user_version = 1")
                } else if schema != 1 {
                    throw SnapshotStoreError.unsupportedSchema
                }
                _ = try Self.read(db)
            }
        }
    }

    public func load() throws -> StoredSnapshot {
        try connection { db in try Self.read(db) }
    }

    @discardableResult
    public func save(_ payload: Data, expected: StoreVersion) throws -> StoreVersion {
        guard !payload.isEmpty, payload.count <= Self.maxPayload else {
            throw SnapshotStoreError.invalidPayload
        }
        return try connection { db in
            try Self.transaction(db) {
                let current = try Self.read(db)
                guard current.version == expected else { throw SnapshotStoreError.staleVersion }
                guard expected.revision < Int64.max else { throw SnapshotStoreError.revisionOverflow }
                let next = StoreVersion(epoch: expected.epoch, revision: expected.revision + 1)
                try Self.write(db, version: next, payload: payload)
                return next
            }
        }
    }

    /// Logical reset only. Old backups and filesystem remnants are not erased by this operation.
    @discardableResult
    public func reset(expected: StoreVersion) throws -> StoreVersion {
        try connection { db in
            try Self.transaction(db) {
                let current = try Self.read(db)
                guard current.version == expected else { throw SnapshotStoreError.staleVersion }
                let next = StoreVersion(epoch: UUID(), revision: 0)
                try Self.write(db, version: next, payload: nil)
                return next
            }
        }
    }

    private func connection<T>(create: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        defer { sqlite3_close(handle) }
        guard status == SQLITE_OK, let db = handle else { throw SnapshotStoreError.sqlite(status) }
        try Self.check(sqlite3_busy_timeout(db, 5000))
        try Self.execute(db, "PRAGMA synchronous = FULL")
        try Self.execute(db, "PRAGMA trusted_schema = OFF")
        if !create {
            guard try Self.scalar(db, "PRAGMA user_version") == 1 else {
                throw SnapshotStoreError.unsupportedSchema
            }
        }
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

    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        try statement(db, sql) { stmt in
            try check(sqlite3_step(stmt), expected: SQLITE_ROW)
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private static func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute(db, "COMMIT")
            return result
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private static func read(_ db: OpaquePointer) throws -> StoredSnapshot {
        try statement(db, "SELECT epoch, revision, payload FROM snapshot WHERE id = 1") { stmt in
            try check(sqlite3_step(stmt), expected: SQLITE_ROW)
            guard sqlite3_column_type(stmt, 0) == SQLITE_TEXT,
                  sqlite3_column_type(stmt, 1) == SQLITE_INTEGER,
                  let raw = sqlite3_column_text(stmt, 0),
                  let epoch = UUID(uuidString: String(cString: raw))
            else { throw SnapshotStoreError.invalidSnapshot }
            let revision = sqlite3_column_int64(stmt, 1)
            let payload: Data?
            if sqlite3_column_type(stmt, 2) == SQLITE_NULL, revision == 0 {
                payload = nil
            } else {
                let count = Int(sqlite3_column_bytes(stmt, 2))
                guard revision > 0, sqlite3_column_type(stmt, 2) == SQLITE_BLOB,
                      count > 0, count <= maxPayload, let bytes = sqlite3_column_blob(stmt, 2)
                else { throw SnapshotStoreError.invalidSnapshot }
                payload = Data(bytes: bytes, count: count)
            }
            return StoredSnapshot(version: .init(epoch: epoch, revision: revision), payload: payload)
        }
    }

    private static func write(_ db: OpaquePointer, version: StoreVersion, payload: Data?) throws {
        try statement(db, "UPDATE snapshot SET epoch = ?, revision = ?, payload = ? WHERE id = 1") { stmt in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try check(sqlite3_bind_text(stmt, 1, version.epoch.uuidString, -1, transient))
            try check(sqlite3_bind_int64(stmt, 2, version.revision))
            if let payload {
                try payload.withUnsafeBytes { bytes in
                    try check(sqlite3_bind_blob(stmt, 3, bytes.baseAddress, Int32(bytes.count), transient))
                }
            } else {
                try check(sqlite3_bind_null(stmt, 3))
            }
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            guard sqlite3_changes(db) == 1 else { throw SnapshotStoreError.invalidSnapshot }
        }
    }
}
