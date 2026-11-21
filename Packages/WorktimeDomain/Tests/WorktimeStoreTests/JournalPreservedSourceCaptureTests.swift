import Foundation
import Testing
@testable import WorktimeStore

struct JournalPreservedSourceCaptureTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func `preserved source retains identity without mutation`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            _ = try SnapshotStore(url: url, createIfMissing: true)
            let baseline = try JournalPreservedSourceCapture.read(at: url)
            try baseline.verifyUnchanged(at: url)
            let reloaded = try JournalPreservedSourceCapture.read(at: url)
            #expect(reloaded.snapshot == baseline.snapshot)
            #expect(reloaded.identity == baseline.identity)
        }
    }

    @Test func `replacement with an identical snapshot fails the physical identity fence`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            let replacement = root.appendingPathComponent("replacement.sqlite")
            _ = try SnapshotStore(url: url, createIfMissing: true)
            let baseline = try JournalPreservedSourceCapture.read(at: url)
            let bytes = try Data(contentsOf: url)
            try FileManager.default.copyItem(at: url, to: replacement)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)
            let current = try JournalPreservedSourceCapture.read(at: url)
            let replacedBytes = try Data(contentsOf: url)
            #expect(current.snapshot == baseline.snapshot)
            #expect(replacedBytes == bytes)
            #expect(current.identity != baseline.identity)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try baseline.verifyUnchanged(at: url)
            }
        }
    }

    @Test func `source update with stable file identity fails the snapshot fence`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            let store = try SnapshotStore(url: url, createIfMissing: true)
            let baseline = try JournalPreservedSourceCapture.read(at: url)
            _ = try store.save(Data([1]), expected: baseline.snapshot.version)
            let current = try JournalPreservedSourceCapture.read(at: url)
            #expect(current.identity == baseline.identity)
            #expect(current.snapshot != baseline.snapshot)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try baseline.verifyUnchanged(at: url)
            }
        }
    }
}
