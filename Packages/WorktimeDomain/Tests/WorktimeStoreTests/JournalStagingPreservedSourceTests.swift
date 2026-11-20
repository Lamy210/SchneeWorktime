import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingPreservedSourceTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func `staging a preserved schema one source never changes the original`() throws {
        try withRoot { root in
            let sourceURL = root.appendingPathComponent("live.sqlite")
            let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
            let initial = try repo.load(now: 90)
            let saved = try repo.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let before = try Data(contentsOf: sourceURL)
            let candidate = try JournalStagingDatabase.createFromPreservedSource(
                at: sourceURL, in: root, now: 120
            )
            let verified = try JournalStagingDatabase.inspect(candidate.url, now: 130)
            #expect(verified.source == saved.validatedSnapshot)
            #expect(verified.catalog == saved.catalog)
            #expect(try Data(contentsOf: sourceURL) == before)
            #expect(candidate.url != sourceURL)
            #expect(throws: SnapshotStoreError.unsupportedSchema) {
                try SnapshotStore(url: candidate.url)
            }
        }
    }

    @Test func `a missing source never creates a staging candidate`() throws {
        try withRoot { root in
            let missing = root.appendingPathComponent("missing.sqlite")
            #expect(throws: DatabaseFileError.self) {
                try JournalStagingDatabase.createFromPreservedSource(at: missing, in: root, now: 100)
            }
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(entries.isEmpty)
        }
    }

    @Test func `schema two candidate cannot be used as a schema one source`() throws {
        try withRoot { root in
            let sourceURL = root.appendingPathComponent("live.sqlite")
            let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
            let session = try repo.load(now: 100)
            let candidate = try JournalStagingDatabase.create(
                source: session.validatedSnapshot, in: root, now: 100
            )
            let existing = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
            #expect(throws: SnapshotStoreError.unsupportedSchema) {
                try JournalStagingDatabase.createFromPreservedSource(
                    at: candidate.url, in: root, now: 100
                )
            }
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == existing)
            #expect(try repo.load(now: 100).version == session.version)
        }
    }
}
