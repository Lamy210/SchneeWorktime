import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalStagingSourcePreflightTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func `matching live source passes read only preflight`() throws {
        try withRoot { root in
            let sourceURL = root.appendingPathComponent("live.sqlite")
            let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
            let initial = try repo.load(now: 90)
            let saved = try repo.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let candidate = try JournalStagingDatabase.create(
                source: saved.validatedSnapshot, in: root, now: 120
            )
            let liveBefore = try Data(contentsOf: sourceURL)
            let candidateBefore = try Data(contentsOf: candidate.url)
            let inspected = try repo.inspectJournalV2Candidate(candidate.url, now: 130)
            #expect(inspected.source == saved.validatedSnapshot)
            #expect(inspected.catalog == saved.catalog)
            #expect(try Data(contentsOf: sourceURL) == liveBefore)
            #expect(try Data(contentsOf: candidate.url) == candidateBefore)
        }
    }

    @Test func `stale candidate is rejected after committed event without altering live data`() throws {
        try withRoot { root in
            let sourceURL = root.appendingPathComponent("live.sqlite")
            let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
            let initial = try repo.load(now: 90)
            let saved = try repo.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            let candidate = try JournalStagingDatabase.create(
                source: saved.validatedSnapshot, in: root, now: 110
            )
            let newer = try repo.apply(
                .clockOut(confirmBreak: false), at: 140, now: 140, expected: saved.version
            )
            let bytes = try Data(contentsOf: sourceURL)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repo.inspectJournalV2Candidate(candidate.url, now: 150)
            }
            #expect(try repo.load(now: 150).version == newer.version)
            #expect(try Data(contentsOf: sourceURL) == bytes)
        }
    }

    @Test func `same revision from a different database is rejected`() throws {
        try withRoot { root in
            let source = try CatalogRepository(
                url: root.appendingPathComponent("source.sqlite"), createIfMissing: true
            )
            let other = try CatalogRepository(
                url: root.appendingPathComponent("other.sqlite"), createIfMissing: true
            )
            let initialSource = try source.load(now: 90)
            let initialOther = try other.load(now: 90)
            let savedSource = try source.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()),
                at: 100, now: 100, expected: initialSource.version
            )
            let savedOther = try other.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()),
                at: 100, now: 100, expected: initialOther.version
            )
            #expect(savedSource.version.revision == savedOther.version.revision)
            #expect(savedSource.version.epoch != savedOther.version.epoch)
            let candidate = try JournalStagingDatabase.create(
                source: savedSource.validatedSnapshot, in: root, now: 120
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try other.inspectJournalV2Candidate(candidate.url, now: 130)
            }
            #expect(try source.inspectJournalV2Candidate(candidate.url, now: 130).catalog == savedSource.catalog)
        }
    }
}
