import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CatalogBackupTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(url, CatalogRepository(url: url, createIfMissing: true))
    }

    @Test func `backup preserves committed observations and audit without changing the store`() throws {
        try withRepository { url, repo in
            let id = UUID()
            let initial = try repo.load(now: 100)
            let command = WorkdayCommand.clockIn(id: id, profile: try WorkdayProfile())
            let started = try repo.apply(command, at: 100, now: 100, expected: initial.version)
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 120, end: 160), now: 200, expected: started.version
            )
            let preview = try observed.previewReview(
                dayID: id, selection: .init(start: 130, end: 150), classification: .rest, now: 200
            )
            let saved = try repo.commitReview(preview, now: 210)
            let store = try SnapshotStore(url: url)
            try store.saveObservationCheckpoint(dayID: id, observedAt: 210, expected: saved.version)
            let before = try store.load()
            let bytes = try repo.makeBackup(now: 220, expected: saved.version)
            let candidate = try CatalogBackup.inspect(bytes, now: 220)
            #expect(candidate.version == saved.version)
            #expect(candidate.catalog == saved.catalog)
            #expect(candidate.catalog.reviewAudit.count == 1)
            #expect(try store.load() == before)
            #expect(try store.loadObservationCheckpoint(expected: saved.version)?.observedAt == 210)
            let envelope = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(Set(envelope.keys) == ["schemaVersion", "sourceEpoch", "revision", "payload"])
        }
    }

    @Test func `empty journal can be inspected without mutating it`() throws {
        try withRepository { _, repo in
            let initial = try repo.load(now: 100)
            let bytes = try repo.makeBackup(now: 100, expected: initial.version)
            let candidate = try CatalogBackup.inspect(bytes, now: 100)
            #expect(candidate.version == initial.version)
            #expect(candidate.catalog.days.isEmpty)
        }
    }

    @Test func `stale snapshot version cannot be exported as current`() throws {
        try withRepository { _, repo in
            let initial = try repo.load(now: 100)
            let command = WorkdayCommand.clockIn(id: UUID(), profile: try WorkdayProfile())
            _ = try repo.apply(command, at: 100, now: 100, expected: initial.version)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.makeBackup(now: 101, expected: initial.version)
            }
        }
    }

    @Test func `future events and invalid journal revision are rejected`() throws {
        try withRepository { _, repo in
            let initial = try repo.load(now: 100)
            let command = WorkdayCommand.clockIn(id: UUID(), profile: try WorkdayProfile())
            let started = try repo.apply(command, at: 100, now: 100, expected: initial.version)
            let bytes = try repo.makeBackup(now: 101, expected: started.version)
            #expect(throws: CatalogPersistenceError.futureEvent) {
                try CatalogBackup.inspect(bytes, now: 99)
            }
            let decoded = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            var changed = try #require(decoded)
            changed["revision"] = 2
            let invalid = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: CatalogPersistenceError.invalidJournal) {
                try CatalogBackup.inspect(invalid, now: 101)
            }
        }
    }

    @Test func `corrupt unsupported and oversized archives are rejected`() throws {
        #expect(throws: CatalogBackupError.invalidArchive) {
            try CatalogBackup.inspect(Data("not-json".utf8), now: 100)
        }
        #expect(throws: CatalogBackupError.tooLarge) {
            try CatalogBackup.inspect(Data(count: 24 * 1024 * 1024 + 1), now: 100)
        }
        let unsupported = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "sourceEpoch": UUID().uuidString, "revision": 0
        ])
        #expect(throws: CatalogBackupError.unsupportedVersion) {
            try CatalogBackup.inspect(unsupported, now: 100)
        }
    }

    @Test func `database containing malformed journal is not exported`() throws {
        try withRepository { url, repo in
            let store = try SnapshotStore(url: url)
            let version = try store.save(Data([0, 1, 2]), expected: store.load().version)
            let before = try store.load()
            #expect(throws: CatalogPersistenceError.invalidJournal) {
                try repo.makeBackup(now: 100, expected: version)
            }
            #expect(try store.load() == before)
        }
    }
}
