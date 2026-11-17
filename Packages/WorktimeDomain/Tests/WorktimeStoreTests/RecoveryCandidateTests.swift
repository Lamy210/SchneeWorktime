import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct RecoveryCandidateTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, CatalogRepository(url: root.appendingPathComponent("original.sqlite"), createIfMissing: true))
    }

    @Test func `candidate has a fresh epoch and retains journal without copying checkpoint`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let day = UUID()
            let command = try WorkdayCommand.clockIn(id: day, profile: WorkdayProfile())
            let started = try repo.apply(command, at: 100, now: 100, expected: initial.version)
            let saved = try repo.recordObservation(
                dayID: day, gap: .init(start: 110, end: 120), now: 130, expected: started.version
            )
            try repo.saveObservationCheckpoint(dayID: day, observedAt: 130, expected: saved.version)
            let bytes = try repo.makeBackup(now: 130, expected: saved.version)
            let candidate = try CatalogBackup.createRecoveryCandidate(bytes, in: root, now: 130)
            let restored = try CatalogRepository(url: candidate.databaseURL).load(now: 130)
            #expect(restored.catalog == saved.catalog)
            #expect(restored.version == candidate.candidateVersion)
            #expect(restored.version.revision == saved.version.revision)
            #expect(restored.version.epoch != saved.version.epoch)
            #expect(candidate.sourceVersion == saved.version)
            #expect(try repo.load(now: 130).version == saved.version)
            #expect(try repo.loadObservationCheckpoint(expected: saved.version)?.observedAt == 130)
            let store = try SnapshotStore(url: candidate.databaseURL)
            #expect(try store.loadObservationCheckpoint(expected: restored.version) == nil)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try store.reset(expected: saved.version)
            }
            let permissions = try FileManager.default.attributesOfItem(atPath: candidate.databaseURL.path)
            #expect(permissions[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func `repeat staging never replaces an existing candidate or original`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let bytes = try repo.makeBackup(now: 100, expected: initial.version)
            let first = try CatalogBackup.createRecoveryCandidate(bytes, in: root, now: 100)
            let second = try CatalogBackup.createRecoveryCandidate(bytes, in: root, now: 100)
            #expect(first.databaseURL != second.databaseURL)
            #expect(first.candidateVersion.epoch != second.candidateVersion.epoch)
            #expect(first.candidateVersion.revision == 0)
            #expect(try CatalogRepository(url: first.databaseURL).load(now: 100).catalog.days.isEmpty)
            #expect(try repo.load(now: 100).version == initial.version)
        }
    }

    @Test func `invalid archive creates nothing`() throws {
        try withRepository { root, _ in
            let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(throws: CatalogBackupError.invalidArchive) {
                try CatalogBackup.createRecoveryCandidate(Data([1]), in: root, now: 100)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
        }
    }

    @Test func `unsafe or symlink staging directory is rejected`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let bytes = try repo.makeBackup(now: 100, expected: initial.version)
            let publicDirectory = root.appendingPathComponent("public")
            try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            for url in [publicDirectory, link] {
                #expect(throws: RecoveryCandidateError.unsafeDirectory) {
                    try CatalogBackup.createRecoveryCandidate(bytes, in: url, now: 100)
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: publicDirectory.path).isEmpty)
        }
    }
}
