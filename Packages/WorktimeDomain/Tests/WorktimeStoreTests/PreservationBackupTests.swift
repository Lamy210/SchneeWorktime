import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct PreservationBackupTests {
    private func withPaths(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        for directory in [source, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try body(source.appendingPathComponent("worktime.sqlite"), destination.appendingPathComponent("backup.json"))
    }

    @Test func `read only preservation exports exact committed journal without modifying source`() throws {
        try withPaths { url, destination in
            let repository = try CatalogRepository(url: url, createIfMissing: true)
            let initial = try repository.load(now: 100)
            let id = UUID()
            let started = try repository.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expected: initial.version
            )
            try repository.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: started.version)
            let before = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            let version = try CatalogBackup.writePreservationBackup(from: url, to: destination, now: 200)
            let inspected = try CatalogBackup.inspectFile(at: destination, now: 200)
            #expect(version == started.version)
            #expect(inspected.validatedSnapshot == started.validatedSnapshot)
            #expect(inspected.catalog == started.catalog)
            #expect(try Data(contentsOf: url) == before)
            #expect(throws: BackupFileError.self) {
                try CatalogBackup.writePreservationBackup(from: url, to: destination, now: 200)
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test(arguments: ["-journal", "-wal", "-shm"])
    func `preservation refuses sidecars and leaves source intact`(suffix: String) throws {
        try withPaths { url, destination in
            _ = try CatalogRepository(url: url, createIfMissing: true)
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            let marker = Data([1, 2, 3])
            try marker.write(to: sidecar)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            let before = try Data(contentsOf: url)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try CatalogBackup.writePreservationBackup(from: url, to: destination, now: 200)
            }
            #expect(try Data(contentsOf: url) == before)
            #expect(try Data(contentsOf: sidecar) == marker)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func `missing or malformed source and in place destination cannot be preserved`() throws {
        try withPaths { url, destination in
            #expect(throws: DatabaseFileError.self) {
                try CatalogBackup.writePreservationBackup(from: url, to: destination, now: 200)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let store = try SnapshotStore(url: url, createIfMissing: true)
            _ = try store.save(Data([0, 1, 2]), expected: store.load().version)
            let before = try Data(contentsOf: url)
            #expect(throws: CatalogPersistenceError.invalidJournal) {
                try CatalogBackup.writePreservationBackup(from: url, to: destination, now: 200)
            }
            let inside = url.deletingLastPathComponent().appendingPathComponent("backup.json")
            #expect(throws: BackupFileError.invalidDestination) {
                try CatalogBackup.writePreservationBackup(from: url, to: inside, now: 200)
            }
            #expect(try Data(contentsOf: url) == before)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(!FileManager.default.fileExists(atPath: inside.path))
        }
    }
}
