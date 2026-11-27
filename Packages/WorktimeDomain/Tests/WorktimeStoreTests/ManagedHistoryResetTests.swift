import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct ManagedHistoryResetTests {
    private func fixture(_ body: (URL, JournalV2Repository, ManagedHistoryRegistry) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let repository = try JournalV2Repository(url: url, createIfMissing: true)
        let registry = try ManagedHistoryRegistry(entries: [])
        try ManagedHistoryRegistryFile.publishInitial(registry, in: root)
        try body(url, repository, registry)
    }

    private func start(_ repository: JournalV2Repository) throws -> JournalV2Session {
        try repository.apply(
            .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100,
            matching: repository.load(now: 100), observedAt: 100
        )
    }

    @Test func `durable intent and reset agree on the exact new epoch after reopen`() throws {
        try fixture { url, repository, registry in
            let root = url.deletingLastPathComponent()
            let started = try start(repository)
            let preview = try repository.previewReset(now: 105, matching: started)
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            let intent = try ManagedHistoryErasureIntent(source: started.version, registry: registry, inventory: inventory)
            let cleared = try repository.commitManagedReset(preview, intent: intent, now: 110)
            #expect(cleared.version == StoreVersion(epoch: intent.targetEpoch, revision: 0))
            #expect(cleared.catalog == WorkdayCatalog())
            #expect(cleared.checkpoint == nil)
            let reopened = try JournalV2Repository.inspectReadOnly(url: url, now: 111)
            let persisted = try ManagedHistoryErasureIntentFile.load(in: root)
            #expect(persisted == intent)
            #expect(persisted.assess(
                session: reopened, registry: registry, inventory: inventory
            ) == .needsCompletionVerification)
            #expect(try ManagedHistoryStartupFence.hasPending(in: root))
            let next = try repository.previewReset(now: 112, matching: reopened)
            #expect(throws: ManagedHistoryPersistenceError.pendingIntent) {
                try repository.commitReset(next, now: 112)
            }
            #expect(try repository.load(now: 113).version == cleared.version)
        }
    }

    @Test func `same revision checkpoint conflict rejects managed reset before publication`() throws {
        try fixture { url, repository, registry in
            let root = url.deletingLastPathComponent()
            let started = try start(repository)
            let preview = try repository.previewReset(now: 105, matching: started)
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            let intent = try ManagedHistoryErasureIntent(source: started.version, registry: registry, inventory: inventory)
            let id = try #require(started.catalog.activeID)
            let external = try repository.saveObservationCheckpoint(
                dayID: id, observedAt: 110, now: 110, matching: started
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repository.commitManagedReset(preview, intent: intent, now: 111)
            }
            #expect(try !ManagedHistoryStartupFence.hasPending(in: root))
            let saved = try repository.load(now: 112)
            #expect(JournalV2Repository.sameCommittedState(external, saved))
        }
    }

    @Test func `published intent does not authorize replay after interruption`() throws {
        try fixture { url, repository, registry in
            let root = url.deletingLastPathComponent()
            let started = try start(repository)
            let preview = try repository.previewReset(now: 105, matching: started)
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            let intent = try ManagedHistoryErasureIntent(source: started.version, registry: registry, inventory: inventory)
            try ManagedHistoryErasureIntentFile.publish(intent, in: root)
            #expect(throws: BackupFileError.self) {
                try repository.commitManagedReset(preview, intent: intent, now: 110)
            }
            let saved = try repository.load(now: 111)
            #expect(JournalV2Repository.sameCommittedState(started, saved))
            #expect(try ManagedHistoryErasureIntentFile.load(in: root) == intent)
            #expect(intent.assess(
                session: saved, registry: registry, inventory: inventory
            ) == .needsNewConfirmation)
        }
    }
}
