import Foundation
import Testing
@testable import WorktimeStore

struct SnapshotStoreTests {
    private func withStore(_ body: (URL, SnapshotStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(url, SnapshotStore(url: url, createIfMissing: true))
    }

    @Test func `snapshot survives reopening`() throws {
        try withStore { url, store in
            let empty = try store.load()
            #expect(empty.payload == nil)
            let bytes = Data([0, 1, 255])
            let next = try store.save(bytes, expected: empty.version)
            let reopened = try SnapshotStore(url: url).load()
            #expect(reopened.version == next)
            #expect(reopened.payload == bytes)
        }
    }

    @Test func `independent connections reject stale writes`() throws {
        try withStore { url, first in
            let second = try SnapshotStore(url: url)
            let version = try first.load().version
            let next = try first.save(Data([1]), expected: version)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try second.save(Data([2]), expected: version)
            }
            let value = try second.load()
            #expect(value.version == next)
            #expect(value.payload == Data([1]))
        }
    }

    @Test func `logical reset fences old versions`() throws {
        try withStore { url, store in
            let initial = try store.load().version
            let old = try store.save(Data([1]), expected: initial)
            let reset = try store.reset(expected: old)
            #expect(reset.epoch != old.epoch)
            #expect(reset.revision == 0)
            let reopened = try SnapshotStore(url: url)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try reopened.save(Data([2]), expected: old)
            }
            #expect(try reopened.load().payload == nil)
        }
    }

    @Test func `invalid payload cannot replace valid snapshot`() throws {
        try withStore { _, store in
            let initial = try store.load().version
            let next = try store.save(Data([1]), expected: initial)
            let before = try store.load()
            #expect(throws: SnapshotStoreError.invalidPayload) {
                try store.save(Data(), expected: next)
            }
            #expect(try store.load() == before)
        }
    }

    @Test func `missing database is not recreated by existing handle`() throws {
        try withStore { url, store in
            try FileManager.default.removeItem(at: url)
            #expect(throws: SnapshotStoreError.self) { try store.load() }
            #expect(throws: SnapshotStoreError.self) { try SnapshotStore(url: url) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func `existing empty database is not initialized`() throws {
        try withStore { url, _ in
            try FileManager.default.removeItem(at: url)
            try Data().write(to: url)
            #expect(throws: SnapshotStoreError.unsupportedSchema) {
                try SnapshotStore(url: url, createIfMissing: true)
            }
            #expect(try Data(contentsOf: url).isEmpty)
        }
    }
}
