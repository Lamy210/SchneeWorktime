import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ReadOnlyBackupTests {
    private func fixture(_ run: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("live", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        for directory in [root, live, archive] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try run(live.appendingPathComponent("worktime.sqlite"), archive.appendingPathComponent("saved.json"))
    }

    private func working(at url: URL) throws -> (JournalV2Repository, UUID, JournalV2Session) {
        let repo = try JournalV2Repository(url: url, createIfMissing: true)
        let id = UUID()
        let saved = try repo.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
            matching: repo.load(now: 100), observedAt: 100
        )
        return (repo, id, saved)
    }

    @Test func `read-only backup captures a restorable full Journal without source mutation`() throws {
        try fixture { url, destination in
            let (repo, id, saved) = try working(at: url)
            let snapshot = try JournalV2ReadOnlyInspection(url: url, now: 101)
            let original = try Data(contentsOf: url)
            try snapshot.writeBackup(from: url, to: destination, now: 102)
            let archive = try Data(contentsOf: destination)
            let inspected = try JournalV2Backup.inspect(archive, now: 102)
            #expect(inspected.version == saved.version)
            #expect(inspected.eventCount == 1)
            #expect(inspected.catalog.days.first?.id == id)
            #expect(try Data(contentsOf: url) == original)
            let actual = try repo.load(now: 102)
            #expect(actual.checkpoint == saved.checkpoint)
            #expect(actual.catalog == saved.catalog)
            #expect(try FileManager.default.attributesOfItem(
                atPath: destination.path
            )[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func `checkpoint-only competitor invalidates backup at the same revision`() throws {
        try fixture { url, destination in
            let (repo, id, saved) = try working(at: url)
            let snapshot = try JournalV2ReadOnlyInspection(url: url, now: 101)
            let updated = try repo.saveObservationCheckpoint(
                dayID: id, observedAt: 105, now: 105, matching: saved
            )
            #expect(updated.version == saved.version)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try snapshot.writeBackup(from: url, to: destination, now: 106)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try repo.load(now: 106).checkpoint == updated.checkpoint)
        }
    }

    @Test func `new journal event invalidates old displayed backup`() throws {
        try fixture { url, destination in
            let (repo, _, saved) = try working(at: url)
            let snapshot = try JournalV2ReadOnlyInspection(url: url, now: 101)
            let changed = try repo.apply(
                .startBreak, at: 110, now: 110, matching: saved
            )
            #expect(throws: SnapshotStoreError.staleVersion) {
                try snapshot.writeBackup(from: url, to: destination, now: 111)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try repo.load(now: 111).version == changed.version)
        }
    }

    @Test func `backup destination inside live DB directory is rejected without writes`() throws {
        try fixture { url, _ in
            _ = try working(at: url)
            let snapshot = try JournalV2ReadOnlyInspection(url: url, now: 101)
            let destination = url.deletingLastPathComponent().appendingPathComponent("archive.json")
            let original = try Data(contentsOf: url)
            #expect(throws: BackupFileError.invalidDestination) {
                try snapshot.writeBackup(from: url, to: destination, now: 102)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func `existing backup is never replaced by a second publication`() throws {
        try fixture { url, destination in
            _ = try working(at: url)
            let snapshot = try JournalV2ReadOnlyInspection(url: url, now: 101)
            try snapshot.writeBackup(from: url, to: destination, now: 102)
            let original = try Data(contentsOf: destination)
            #expect(throws: BackupFileError.self) {
                try snapshot.writeBackup(from: url, to: destination, now: 103)
            }
            #expect(try Data(contentsOf: destination) == original)
        }
    }

    @Test func `a stale inspected checkpoint prevents writable activation and recovery`() throws {
        try fixture { url, _ in
            let (repo, id, saved) = try working(at: url)
            let snapshot = try JournalV2ReadOnlyInspection(url: url, now: 101)
            let updated = try repo.saveObservationCheckpoint(
                dayID: id, observedAt: 105, now: 105, matching: saved
            )
            let original = try Data(contentsOf: url)
            let next = try ClockSample(wall: 110, uptime: 110)
            #expect(throws: JournalV2ReadOnlyActivationError.staleSnapshot) {
                try snapshot.openWorkSession(url: url, sample: next)
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(try repo.load(now: 110).checkpoint == updated.checkpoint)
        }
    }

    @Test func `stale journal revision prevents opening a writable recovery session`() throws {
        try fixture { url, _ in
            let (repo, _, saved) = try working(at: url)
            let snapshot = try JournalV2ReadOnlyInspection(url: url, now: 101)
            let current = try repo.apply(.startBreak, at: 110, now: 110, matching: saved)
            let previous = try Data(contentsOf: url)
            let sample = try ClockSample(wall: 112, uptime: 112)
            #expect(throws: JournalV2ReadOnlyActivationError.staleSnapshot) {
                try snapshot.openWorkSession(url: url, sample: sample)
            }
            #expect(try Data(contentsOf: url) == previous)
            #expect(try repo.load(now: 112).version == current.version)
        }
    }
}
