import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingOfflinePreflightTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func `offline comparison accepts an unchanged schema one source`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            let repository = try CatalogRepository(url: url, createIfMissing: true)
            let initial = try repository.load(now: 90)
            let session = try repository.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let candidate = try JournalStagingDatabase.create(
                source: session.validatedSnapshot, in: root, now: 120
            )
            let originalBytes = try Data(contentsOf: url)
            let candidateBytes = try Data(contentsOf: candidate.url)
            let inspected = try JournalStagingDatabase.preflightPreservedSource(
                at: url, candidateURL: candidate.url, now: 130
            )
            #expect(inspected.source == session.validatedSnapshot)
            #expect(inspected.catalog == session.catalog)
            let reloadedSourceBytes = try Data(contentsOf: url)
            let reloadedCandidateBytes = try Data(contentsOf: candidate.url)
            #expect(reloadedSourceBytes == originalBytes)
            #expect(reloadedCandidateBytes == candidateBytes)
        }
    }

    @Test func `offline comparison rejects stale candidate after source mutation`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            let repository = try CatalogRepository(url: url, createIfMissing: true)
            let initial = try repository.load(now: 90)
            let saved = try repository.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let candidate = try JournalStagingDatabase.create(
                source: saved.validatedSnapshot, in: root, now: 110
            )
            let newer = try repository.apply(
                .clockOut(confirmBreak: false), at: 150, now: 150, expected: saved.version
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.preflightPreservedSource(
                    at: url, candidateURL: candidate.url, now: 160
                )
            }
            let reloaded = try repository.load(now: 160)
            #expect(reloaded.version == newer.version)
        }
    }

    @Test func `offline comparison rejects an unrelated source with the same revision`() throws {
        try withRoot { root in
            let sourceURL = root.appendingPathComponent("source.sqlite")
            let otherURL = root.appendingPathComponent("other.sqlite")
            let source = try CatalogRepository(url: sourceURL, createIfMissing: true)
            let other = try CatalogRepository(url: otherURL, createIfMissing: true)
            let sourceSession = try source.load(now: 100)
            let otherSession = try other.load(now: 100)
            #expect(sourceSession.version.revision == otherSession.version.revision)
            #expect(sourceSession.version.epoch != otherSession.version.epoch)
            let candidate = try JournalStagingDatabase.create(
                source: sourceSession.validatedSnapshot, in: root, now: 110
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.preflightPreservedSource(
                    at: otherURL, candidateURL: candidate.url, now: 120
                )
            }
        }
    }

    @Test func `offline comparison rejects symlinked source without changing target`() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("source.sqlite")
            let alias = root.appendingPathComponent("source-alias.sqlite")
            let repository = try CatalogRepository(url: url, createIfMissing: true)
            let session = try repository.load(now: 100)
            let candidate = try JournalStagingDatabase.create(
                source: session.validatedSnapshot, in: root, now: 100
            )
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            let originalBytes = try Data(contentsOf: url)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try JournalStagingDatabase.preflightPreservedSource(
                    at: alias, candidateURL: candidate.url, now: 110
                )
            }
            let after = try Data(contentsOf: url)
            #expect(after == originalBytes)
        }
    }
}
