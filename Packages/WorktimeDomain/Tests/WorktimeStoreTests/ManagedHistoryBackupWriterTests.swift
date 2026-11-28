import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ManagedHistoryBackupWriterTests {
    private func fixture(_ body: (URL, JournalV2Repository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try JournalV2Repository(
            url: root.appendingPathComponent("worktime.sqlite"), createIfMissing: true
        )
        try body(root, repository)
    }

    @Test func `managed backup registration survives reopen without changing live history`() throws {
        try fixture { root, repository in
            try ManagedHistoryBackupWriter.initializeEmpty(in: root)
            let initial = try repository.load(now: 100)
            let session = try repository.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100,
                matching: initial, observedAt: 100
            )
            let first = try repository.writeManagedBackup(now: 101, matching: session)
            let second = try repository.writeManagedBackup(now: 102, matching: session)
            let registry = try ManagedHistoryRegistryFile.load(in: root)
            #expect(registry.entries == [first, second])
            #expect(first.epoch == session.version.epoch)
            #expect(first.id != second.id)
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            #expect(inventory.isComplete)
            #expect(inventory.items.count == 2)
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let bytes = try BackupFile.load(directory.appendingPathComponent(first.name))
            let expected = try repository.makeBackup(now: 101, matching: session)
            #expect(bytes == expected)
            let saved = try repository.load(now: 103)
            #expect(JournalV2Repository.sameCommittedState(saved, session))
        }
    }

    @Test func `unregistered file and existing root are never silently adopted`() throws {
        try fixture { root, repository in
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            let unknown = directory.appendingPathComponent("unknown.json")
            let data = Data("external".utf8)
            try data.write(to: unknown)
            #expect(throws: ManagedHistoryInventoryError.self) {
                try ManagedHistoryBackupWriter.initializeEmpty(in: root)
            }
            #expect(try Data(contentsOf: unknown) == data)
            try ManagedHistoryRegistryFile.publishInitial(ManagedHistoryRegistry(entries: []), in: root)
            let session = try repository.load(now: 100)
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try repository.writeManagedBackup(now: 101, matching: session)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["unknown.json"])
            #expect(try Data(contentsOf: unknown) == data)
        }
    }

    @Test func `pending erasure refuses backup and bootstrap`() throws {
        try fixture { root, repository in
            try ManagedHistoryBackupWriter.initializeEmpty(in: root)
            let registry = try ManagedHistoryRegistryFile.load(in: root)
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            let session = try repository.load(now: 100)
            let intent = try ManagedHistoryErasureIntent(
                source: session.version, registry: registry, inventory: inventory
            )
            try ManagedHistoryErasureIntentFile.publish(intent, in: root)
            #expect(throws: ManagedHistoryPersistenceError.pendingIntent) {
                try repository.writeManagedBackup(now: 101, matching: session)
            }
            #expect(throws: ManagedHistoryPersistenceError.pendingIntent) {
                try ManagedHistoryBackupWriter.initializeEmpty(in: root)
            }
            #expect(try ManagedHistoryRegistryFile.load(in: root) == registry)
        }
    }

    @Test func `metadata byte CAS rejects stale original and preserves current bytes`() throws {
        try fixture { root, _ in
            let file = root.appendingPathComponent("metadata.json")
            let original = Data("original".utf8)
            let next = Data("next".utf8)
            try BackupFile.publish(original, to: file)
            try BackupFile.replaceMetadata(next, at: file, matching: original, maxBytes: 1024)
            #expect(throws: BackupFileError.unsafeFile) {
                try BackupFile.replaceMetadata(original, at: file, matching: original, maxBytes: 1024)
            }
            #expect(try BackupFile.load(file) == next)
        }
    }

    @Test func `interrupted registration preserves unregistered backup and stops further publication`() throws {
        try fixture { root, repository in
            try ManagedHistoryBackupWriter.initializeEmpty(in: root)
            let session = try repository.load(now: 100)
            let bytes = try repository.makeBackup(now: 100, matching: session)
            #expect(throws: ManagedHistoryPersistenceError.verificationFailed) {
                try ManagedHistoryBackupWriter.publish(bytes, epoch: session.version.epoch, in: root) {
                    throw ManagedHistoryPersistenceError.verificationFailed
                }
            }
            let registry = try ManagedHistoryRegistryFile.load(in: root)
            #expect(registry.entries.isEmpty)
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            #expect(!inventory.isComplete)
            let item = try #require(inventory.items.first)
            #expect(item.status == .unregistered)
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            #expect(try BackupFile.load(directory.appendingPathComponent(item.name)) == bytes)
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try repository.writeManagedBackup(now: 101, matching: session)
            }
            let remaining = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            #expect(remaining == inventory)
            let saved = try repository.load(now: 102)
            #expect(JournalV2Repository.sameCommittedState(saved, session))
        }
    }
}
