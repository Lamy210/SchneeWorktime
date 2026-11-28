import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ManagedHistoryFileErasureTests {
    private func fixture(_ body: (URL, JournalV2Repository, ManagedHistoryErasureIntent) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let repository = try JournalV2Repository(url: url, createIfMissing: true)
        try ManagedHistoryBackupWriter.initializeEmpty(in: root)
        let session = try repository.apply(
            .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100,
            matching: repository.load(now: 100), observedAt: 100
        )
        _ = try repository.writeManagedBackup(now: 101, matching: session)
        _ = try repository.writeManagedBackup(now: 102, matching: session)
        let registry = try ManagedHistoryRegistryFile.load(in: root)
        let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
        let intent = try ManagedHistoryErasureIntent(
            source: session.version, registry: registry, inventory: inventory
        )
        try body(url, repository, intent)
    }

    private func reset(
        _ repository: JournalV2Repository, intent: ManagedHistoryErasureIntent
    ) throws {
        let session = try repository.load(now: 103)
        let preview = try repository.previewReset(now: 103, matching: session)
        _ = try repository.commitManagedReset(preview, intent: intent, now: 104)
    }

    @Test func `one file per step and armed interruption resumes without touching external copies`() throws {
        try fixture { url, repository, intent in
            let root = url.deletingLastPathComponent()
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let entries = intent.registry.entries.sorted { $0.name < $1.name }
            let first = directory.appendingPathComponent(entries[0].name)
            let second = directory.appendingPathComponent(entries[1].name)
            let external = root.appendingPathComponent(entries[0].name)
            let bytes = try Data(contentsOf: first)
            try bytes.write(to: external)
            try reset(repository, intent: intent)
            try ManagedHistoryFileErasure.initialize(databaseURL: url, intent: intent, now: 105)
            #expect(throws: ManagedHistoryPersistenceError.verificationFailed) {
                try ManagedHistoryFileErasure.advance(databaseURL: url, intent: intent, now: 106) {
                    throw ManagedHistoryPersistenceError.verificationFailed
                }
            }
            let interrupted = try ManagedHistoryErasureProgressFile.load(in: root, intent: intent).progress
            #expect(interrupted.armed)
            #expect(interrupted.completedCount == 0)
            #expect(!FileManager.default.fileExists(atPath: first.path))
            #expect(FileManager.default.fileExists(atPath: second.path))
            #expect(try ManagedHistoryFileErasure.advance(
                databaseURL: url, intent: intent, now: 107
            ) == .advanced(completed: 1, total: 2))
            #expect(FileManager.default.fileExists(atPath: second.path))
            #expect(try ManagedHistoryFileErasure.advance(
                databaseURL: url, intent: intent, now: 108
            ) == .advanced(completed: 2, total: 2))
            #expect(try ManagedHistoryFileErasure.advance(
                databaseURL: url, intent: intent, now: 109
            ) == .needsCompletionVerification)
            #expect(try Data(contentsOf: external) == bytes)
            #expect(try ManagedHistoryStartupFence.hasPending(in: root))
            let saved = try JournalV2Repository.inspectReadOnly(url: url, now: 110)
            #expect(saved.version.epoch == intent.targetEpoch)
            #expect(saved.catalog == WorkdayCatalog())
        }
    }

    @Test func `unarmed missing file blocks rather than being counted as erased`() throws {
        try fixture { url, repository, intent in
            let root = url.deletingLastPathComponent()
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let entries = intent.registry.entries.sorted { $0.name < $1.name }
            try reset(repository, intent: intent)
            try ManagedHistoryFileErasure.initialize(databaseURL: url, intent: intent, now: 105)
            try FileManager.default.removeItem(at: directory.appendingPathComponent(entries[1].name))
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try ManagedHistoryFileErasure.advance(databaseURL: url, intent: intent, now: 106)
            }
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entries[0].name).path))
            let progress = try ManagedHistoryErasureProgressFile.load(in: root, intent: intent).progress
            #expect(progress == ManagedHistoryErasureProgress(intent: intent))
        }
    }

    @Test func `changed file and old generation block deletion`() throws {
        try fixture { url, repository, intent in
            let root = url.deletingLastPathComponent()
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let entry = try #require(intent.registry.entries.first)
            let file = directory.appendingPathComponent(entry.name)
            try ManagedHistoryErasureIntentFile.publish(intent, in: root)
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try ManagedHistoryFileErasure.initialize(databaseURL: url, intent: intent, now: 103)
            }
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent(ManagedHistoryErasureProgressFile.filename).path
            ))
            let session = try repository.load(now: 104)
            #expect(session.version.epoch == intent.sourceEpoch)
        }
        try fixture { url, repository, intent in
            let root = url.deletingLastPathComponent()
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let entry = try #require(intent.registry.entries.first)
            let file = directory.appendingPathComponent(entry.name)
            try reset(repository, intent: intent)
            try ManagedHistoryFileErasure.initialize(databaseURL: url, intent: intent, now: 105)
            let bytes = Data("changed content".utf8)
            try bytes.write(to: file)
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try ManagedHistoryFileErasure.advance(databaseURL: url, intent: intent, now: 106)
            }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func `orphan progress is a startup fence even without an intent`() throws {
        try fixture { url, _, intent in
            let root = url.deletingLastPathComponent()
            #expect(try !ManagedHistoryStartupFence.hasPending(in: root))
            try ManagedHistoryErasureProgressFile.publish(ManagedHistoryErasureProgress(intent: intent), in: root)
            #expect(try ManagedHistoryStartupFence.hasPending(in: root))
        }
    }
}
