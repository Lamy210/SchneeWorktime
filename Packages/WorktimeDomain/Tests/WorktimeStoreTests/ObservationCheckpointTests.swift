import Foundation
import Testing
@testable import WorktimeStore

struct ObservationCheckpointTests {
    private func withStore(_ body: (URL, SnapshotStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(url, SnapshotStore(url: url, createIfMissing: true))
    }

    @Test func `legacy database has no checkpoint and loading does not change snapshot`() throws {
        try withStore { _, store in
            let before = try store.load()
            #expect(try store.loadObservationCheckpoint(expected: before.version) == nil)
            #expect(try store.load() == before)
            #expect(throws: ObservationCheckpointError.invalid) {
                try store.saveObservationCheckpoint(dayID: UUID(), observedAt: 100, expected: before.version)
            }
        }
    }

    @Test func `checkpoint persists without advancing journal revision`() throws {
        try withStore { url, store in
            let initial = try store.load().version
            let version = try store.save(Data([1]), expected: initial)
            let day = UUID()
            let before = try store.load()
            try store.saveObservationCheckpoint(dayID: day, observedAt: 100, expected: version)
            try store.saveObservationCheckpoint(dayID: day, observedAt: 100, expected: version)
            try store.saveObservationCheckpoint(dayID: day, observedAt: 120, expected: version)
            let reopened = try SnapshotStore(url: url)
            let marker = try reopened.loadObservationCheckpoint(expected: version)
            #expect(marker?.version == version)
            #expect(marker?.dayID == day)
            #expect(marker?.observedAt == 120)
            #expect(try reopened.load() == before)
        }
    }

    @Test func `regressed time or different day cannot replace a marker at the same revision`() throws {
        try withStore { _, store in
            let version = try store.save(Data([1]), expected: store.load().version)
            let day = UUID()
            try store.saveObservationCheckpoint(dayID: day, observedAt: 100, expected: version)
            #expect(throws: ObservationCheckpointError.regressed) {
                try store.saveObservationCheckpoint(dayID: day, observedAt: 99, expected: version)
            }
            #expect(throws: ObservationCheckpointError.conflictingDay) {
                try store.saveObservationCheckpoint(dayID: UUID(), observedAt: 101, expected: version)
            }
            #expect(try store.loadObservationCheckpoint(expected: version)?.observedAt == 100)
        }
    }

    @Test func `a new journal revision fences stale checkpoint writers and readers`() throws {
        try withStore { url, store in
            let old = try store.save(Data([1]), expected: store.load().version)
            let day = UUID()
            try store.saveObservationCheckpoint(dayID: day, observedAt: 100, expected: old)
            let other = try SnapshotStore(url: url)
            let version = try other.save(Data([2]), expected: old)
            #expect(try other.loadObservationCheckpoint(expected: version) == nil)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try store.loadObservationCheckpoint(expected: old)
            }
            #expect(throws: SnapshotStoreError.staleVersion) {
                try store.saveObservationCheckpoint(dayID: day, observedAt: 101, expected: old)
            }
            try other.saveObservationCheckpoint(dayID: day, observedAt: 102, expected: version)
            #expect(try other.loadObservationCheckpoint(expected: version)?.observedAt == 102)
        }
    }

    @Test func `reset prevents reuse of a checkpoint from the old epoch`() throws {
        try withStore { _, store in
            let old = try store.save(Data([1]), expected: store.load().version)
            try store.saveObservationCheckpoint(dayID: UUID(), observedAt: 100, expected: old)
            let reset = try store.reset(expected: old)
            let version = try store.save(Data([2]), expected: reset)
            #expect(old.revision == version.revision)
            #expect(old.epoch != version.epoch)
            #expect(try store.loadObservationCheckpoint(expected: version) == nil)
        }
    }

    @Test func `out of range time is rejected without creating a checkpoint`() throws {
        try withStore { _, store in
            let version = try store.save(Data([1]), expected: store.load().version)
            #expect(throws: ObservationCheckpointError.invalid) {
                try store.saveObservationCheckpoint(dayID: UUID(), observedAt: Int64.max, expected: version)
            }
            #expect(try store.loadObservationCheckpoint(expected: version) == nil)
        }
    }
}
