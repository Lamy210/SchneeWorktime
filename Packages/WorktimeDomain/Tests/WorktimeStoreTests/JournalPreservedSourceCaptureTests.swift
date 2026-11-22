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

    @Test func `checkpoint update with identical snapshot is detected`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            let repository = try CatalogRepository(url: url, createIfMissing: true)
            let initial = try repository.load(now: 90)
            let id = UUID()
            let active = try repository.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let store = try SnapshotStore(url: url)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: active.version)
            let before = try JournalPreservedSourceCapture.read(at: url)
            #expect(before.checkpoint?.observedAt == 110)
            #expect(before.checkpoint?.version == active.version)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 120, expected: active.version)
            let after = try JournalPreservedSourceCapture.read(at: url)
            #expect(after.identity == before.identity)
            #expect(after.snapshot == before.snapshot)
            #expect(after.checkpoint?.observedAt == 120)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try before.verifyUnchanged(at: url)
            }
        }
    }

    @Test func `stale checkpoint from a prior Journal revision is never rebound`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            let repository = try CatalogRepository(url: url, createIfMissing: true)
            let initial = try repository.load(now: 90)
            let id = UUID()
            let active = try repository.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let store = try SnapshotStore(url: url)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: active.version)
            let changed = try repository.setFutureRest(
                dayID: id, remainingSeconds: 120, now: 130, expected: active.version
            )
            #expect(changed.version != active.version)
            let captured = try JournalPreservedSourceCapture.read(at: url)
            #expect(captured.snapshot == changed.validatedSnapshot)
            #expect(captured.checkpoint == nil)
            #expect(try store.loadObservationCheckpoint(expected: changed.version) == nil)
            try captured.verifyUnchanged(at: url)
        }
    }

    @Test func `read only capture does not create checkpoint or alter source bytes`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            let store = try SnapshotStore(url: url, createIfMissing: true)
            let bytes = try Data(contentsOf: url)
            let captured = try JournalPreservedSourceCapture.read(at: url)
            let loaded = try store.load()
            #expect(captured.snapshot == loaded)
            #expect(captured.checkpoint == nil)
            try captured.verifyUnchanged(at: url)
            let after = try Data(contentsOf: url)
            #expect(after == bytes)
        }
    }
}
