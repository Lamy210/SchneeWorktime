import Foundation
import Testing
@testable import WorktimeStore

struct DatabaseFileGuardTests {
    private func withStore(_ body: (URL, SnapshotStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worktime.sqlite")
        try body(url, SnapshotStore(url: url, createIfMissing: true))
    }

    @Test func `new database is private and broad permissions are rejected without mutation`() throws {
        try withStore { url, store in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            let before = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(throws: DatabaseFileError.unsafeFile) { try store.load() }
            #expect(throws: DatabaseFileError.unsafeFile) { try SnapshotStore(url: url) }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test(arguments: [false, true])
    func `database links are rejected before sqlite opens`(hardLink: Bool) throws {
        try withStore { url, store in
            let original = url.deletingLastPathComponent().appendingPathComponent("original.sqlite")
            try FileManager.default.moveItem(at: url, to: original)
            let before = try Data(contentsOf: original)
            if hardLink {
                try FileManager.default.linkItem(at: original, to: url)
            } else {
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
            }
            #expect(throws: DatabaseFileError.unsafeFile) { try store.load() }
            #expect(throws: DatabaseFileError.unsafeFile) { try SnapshotStore(url: url, createIfMissing: true) }
            #expect(try Data(contentsOf: original) == before)
        }
    }

    @Test(arguments: ["-journal", "-wal", "-shm"])
    func `sqlite sidecar symlinks are rejected without touching their target`(suffix: String) throws {
        try withStore { url, store in
            let target = url.deletingLastPathComponent().appendingPathComponent("unrelated")
            let bytes = Data([1, 2, 3])
            try bytes.write(to: target)
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
            #expect(throws: DatabaseFileError.unsafeFile) { try store.load() }
            #expect(try Data(contentsOf: target) == bytes)
        }
    }

    @Test func `dangling database link cannot be initialized`() throws {
        try withStore { url, _ in
            try FileManager.default.removeItem(at: url)
            let target = url.deletingLastPathComponent().appendingPathComponent("missing")
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            #expect(throws: DatabaseFileError.unsafeFile) { try SnapshotStore(url: url, createIfMissing: true) }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }
}
