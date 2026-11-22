import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalPreservedSourceCaptureSemanticTests {
    private func withActiveDay(_ body: (URL, StoreVersion, UUID) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.sqlite")
        let repo = try CatalogRepository(url: url, createIfMissing: true)
        let initial = try repo.load(now: 90)
        let dayID = UUID()
        let active = try repo.apply(
            .clockIn(id: dayID, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
        )
        try body(url, active.version, dayID)
    }

    @Test func `checkpoint for unrelated active day cannot be used for migration`() throws {
        try withActiveDay { url, version, _ in
            let store = try SnapshotStore(url: url)
            try store.saveObservationCheckpoint(dayID: UUID(), observedAt: 110, expected: version)
            let before = try Data(contentsOf: url)
            #expect(throws: ObservationCheckpointError.invalid) {
                try JournalPreservedSourceCapture.read(at: url)
            }
            #expect(try Data(contentsOf: url) == before)
            let stored = try store.load()
            #expect(stored.version == version)
        }
    }

    @Test func `checkpoint before clock in is rejected without changing the original`() throws {
        try withActiveDay { url, version, id in
            let store = try SnapshotStore(url: url)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 90, expected: version)
            let before = try Data(contentsOf: url)
            #expect(throws: ObservationCheckpointError.invalid) {
                try JournalPreservedSourceCapture.read(at: url)
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func `valid active checkpoint is preserved and requires no write`() throws {
        try withActiveDay { url, version, id in
            let store = try SnapshotStore(url: url)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: version)
            let before = try Data(contentsOf: url)
            let captured = try JournalPreservedSourceCapture.read(at: url)
            #expect(captured.checkpoint?.dayID == id)
            #expect(captured.checkpoint?.version == version)
            #expect(captured.checkpoint?.observedAt == 110)
            try captured.verifyUnchanged(at: url)
            #expect(try Data(contentsOf: url) == before)
        }
    }
}
