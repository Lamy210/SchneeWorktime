import CSQLite
import Foundation
import Testing
@testable import WorktimeStore

struct WorktimeDatabaseFormatProbeTests {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder, folder.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `missing database is detected without creating directories or sqlite files`() throws {
        try fixture { _, url in
            #expect(try WorktimeDatabaseFormatProbe.inspect(url: url) == .missing)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func `schema one development database stays byte identical after read-only probe`() throws {
        try fixture { _, url in
            _ = try SnapshotStore(url: url, createIfMissing: true)
            let before = try Data(contentsOf: url)
            let identity = try DatabaseFileGuard.identity(url)
            #expect(try WorktimeDatabaseFormatProbe.inspect(url: url) == .schemaOne)
            #expect(try Data(contentsOf: url) == before)
            #expect(try DatabaseFileGuard.identity(url) == identity)
        }
    }

    @Test func `schema two journal and checkpoint remain unchanged after format detection`() throws {
        try fixture { _, url in
            let repository = try JournalV2Repository(url: url, createIfMissing: true)
            let start = try repository.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100,
                matching: repository.load(now: 100), observedAt: 100
            )
            let bytes = try Data(contentsOf: url)
            #expect(try WorktimeDatabaseFormatProbe.inspect(url: url) == .schemaTwo)
            let after = try repository.load(now: 101)
            #expect(after.version == start.version)
            #expect(after.catalog == start.catalog)
            #expect(after.checkpoint == start.checkpoint)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func `unknown sqlite user version is never classified as supported`() throws {
        try fixture { _, url in
            var handle: OpaquePointer?
            #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
            guard let db = handle else { throw SnapshotStoreError.invalidSnapshot }
            #expect(sqlite3_exec(db, "PRAGMA user_version = 17", nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_close(db) == SQLITE_OK)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let before = try Data(contentsOf: url)
            #expect(try WorktimeDatabaseFormatProbe.inspect(url: url) == .unknown)
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func `symbolic and hard links cannot be treated as a safe schema two database`() throws {
        try fixture { root, url in
            _ = try JournalV2Repository(url: url, createIfMissing: true)
            let symlink = root.appendingPathComponent("symlink.sqlite")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try WorktimeDatabaseFormatProbe.inspect(url: symlink)
            }
            let hardlink = root.appendingPathComponent("hardlink.sqlite")
            try FileManager.default.linkItem(at: url, to: hardlink)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try WorktimeDatabaseFormatProbe.inspect(url: hardlink)
            }
        }
    }

    @Test func `hot sqlite sidecar is refused instead of opening or repairing it`() throws {
        try fixture { _, url in
            _ = try JournalV2Repository(url: url, createIfMissing: true)
            let sidecar = URL(fileURLWithPath: url.path + "-journal")
            try Data([1, 2, 3]).write(to: sidecar, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: sidecar.path
            )
            #expect(throws: DatabaseFileError.unsafeFile) {
                try WorktimeDatabaseFormatProbe.inspect(url: url)
            }
            #expect(try Data(contentsOf: sidecar) == Data([1, 2, 3]))
        }
    }
}
