import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ManagedHistoryErasureCompletionTests {
    private func fixture(_ body: (URL, ManagedHistoryErasureIntent) throws -> Void) throws {
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
        let registry = try ManagedHistoryRegistryFile.load(in: root)
        let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
        let intent = try ManagedHistoryErasureIntent(
            source: session.version, registry: registry, inventory: inventory
        )
        let preview = try repository.previewReset(now: 102, matching: session)
        _ = try repository.commitManagedReset(preview, intent: intent, now: 103)
        try ManagedHistoryFileErasure.initialize(databaseURL: url, intent: intent, now: 104)
        try body(url, intent)
    }

    @Test func `completion refuses unprocessed files and retains all markers`() throws {
        try fixture { url, intent in
            let root = url.deletingLastPathComponent()
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try ManagedHistoryErasureCompletion.finish(databaseURL: url, intent: intent, now: 105)
            }
            #expect(try ManagedHistoryRegistryFile.load(in: root) == intent.registry)
            #expect(try ManagedHistoryStartupFence.hasPending(in: root))
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent(ManagedHistoryErasureCompletion.filename).path
            ))
        }
    }

    @Test func `finalization resumes at each durable boundary and preserves an external copy`() throws {
        let stages: [ManagedHistoryErasureCompletion.Stage] = [
            .receiptPublished, .registryCleared, .progressRemoved, .intentRemoved
        ]
        for stage in stages {
            try fixture { url, intent in
                let root = url.deletingLastPathComponent()
                let entry = try #require(intent.registry.entries.first)
                let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
                let external = root.appendingPathComponent(entry.name)
                let data = try Data(contentsOf: directory.appendingPathComponent(entry.name))
                try data.write(to: external)
                _ = try ManagedHistoryFileErasure.advance(databaseURL: url, intent: intent, now: 105)
                #expect(throws: ManagedHistoryPersistenceError.verificationFailed) {
                    try ManagedHistoryErasureCompletion.finish(databaseURL: url, intent: intent, now: 106) {
                        if $0 == stage { throw ManagedHistoryPersistenceError.verificationFailed }
                    }
                }
                #expect(try ManagedHistoryStartupFence.hasPending(in: root))
                try ManagedHistoryErasureCompletion.finish(databaseURL: url, intent: intent, now: 107)
                #expect(try !ManagedHistoryStartupFence.hasPending(in: root))
                let registry = try ManagedHistoryRegistryFile.load(in: root)
                #expect(registry.entries.isEmpty)
                let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
                #expect(inventory.isComplete)
                #expect(inventory.items.isEmpty)
                #expect(try Data(contentsOf: external) == data)
                let session = try JournalV2Repository.inspectReadOnly(url: url, now: 108)
                #expect(session.version.epoch == intent.targetEpoch)
                #expect(session.catalog == WorkdayCatalog())
            }
        }
    }

    @Test func `unknown file after receipt publication blocks finalization`() throws {
        try fixture { url, intent in
            let root = url.deletingLastPathComponent()
            _ = try ManagedHistoryFileErasure.advance(databaseURL: url, intent: intent, now: 105)
            #expect(throws: ManagedHistoryPersistenceError.verificationFailed) {
                try ManagedHistoryErasureCompletion.finish(databaseURL: url, intent: intent, now: 106) {
                    if $0 == .receiptPublished { throw ManagedHistoryPersistenceError.verificationFailed }
                }
            }
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let unknown = directory.appendingPathComponent("unknown.json")
            let bytes = Data("unregistered".utf8)
            try bytes.write(to: unknown)
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try ManagedHistoryErasureCompletion.finish(databaseURL: url, intent: intent, now: 107)
            }
            #expect(try Data(contentsOf: unknown) == bytes)
            #expect(try ManagedHistoryStartupFence.hasPending(in: root))
            #expect(try ManagedHistoryRegistryFile.load(in: root) == intent.registry)
        }
    }
}
