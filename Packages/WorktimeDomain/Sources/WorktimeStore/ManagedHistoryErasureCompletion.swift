import Foundation
import WorktimeDomain

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Finalization is a separate, explicit maintenance operation. The immutable
/// receipt preserves the full intent after the earlier markers are removed.
/// It remains a startup fence until all other changes are durable.
enum ManagedHistoryErasureCompletion {
    static let filename = "managed-history-erasure-completion-v1.json"

    enum Stage: Equatable {
        case receiptPublished, registryCleared, progressRemoved, intentRemoved
    }

    private struct State {
        let intentBytes: Data?
        let progressBytes: Data?
        let registry: ManagedHistoryRegistry
        let registryBytes: Data
    }

    /// Caller holds the exclusive owner lock, stops writers and notifications
    /// and confirms the maintenance operation. No automatic launch-time resume.
    static func finish(
        databaseURL: URL, intent: ManagedHistoryErasureIntent, now: Int64,
        afterStage: (Stage) throws -> Void = { _ in }
    ) throws {
        try intent.validate()
        let root = databaseURL.deletingLastPathComponent()
        let receiptURL = root.appendingPathComponent(filename)
        let receipt = try optionalBytes(receiptURL, maxBytes: ManagedHistoryErasureIntent.maxBytes)
        if let receipt {
            guard try ManagedHistoryErasureIntent.decode(receipt) == intent else {
                throw ManagedHistoryPersistenceError.invalidIntent
            }
        } else {
            let state = try inspect(databaseURL: databaseURL, intent: intent, now: now)
            guard state.intentBytes != nil, state.progressBytes != nil, state.registry == intent.registry else {
                throw ManagedHistoryPersistenceError.incompleteInventory
            }
            let data = try JSONEncoder().encode(intent)
            try BackupFile.publish(data, to: receiptURL, maxBytes: ManagedHistoryErasureIntent.maxBytes)
            try afterStage(.receiptPublished)
        }
        let persisted = try BackupFile.load(receiptURL, maxBytes: ManagedHistoryErasureIntent.maxBytes)
        guard try ManagedHistoryErasureIntent.decode(persisted) == intent else {
            throw ManagedHistoryPersistenceError.invalidIntent
        }
        try clearRegistry(databaseURL: databaseURL, intent: intent, now: now)
        try afterStage(.registryCleared)
        var state = try inspect(databaseURL: databaseURL, intent: intent, now: now)
        if let bytes = state.progressBytes {
            try BackupFile.removeMetadata(
                at: root.appendingPathComponent(ManagedHistoryErasureProgressFile.filename),
                matching: bytes, maxBytes: ManagedHistoryErasureProgressFile.maxBytes
            )
            try afterStage(.progressRemoved)
        }
        state = try inspect(databaseURL: databaseURL, intent: intent, now: now)
        if let bytes = state.intentBytes {
            try BackupFile.removeMetadata(
                at: root.appendingPathComponent(ManagedHistoryErasureIntentFile.filename),
                matching: bytes, maxBytes: ManagedHistoryErasureIntent.maxBytes
            )
            try afterStage(.intentRemoved)
        }
        state = try inspect(databaseURL: databaseURL, intent: intent, now: now)
        guard state.registry.entries.isEmpty, state.progressBytes == nil, state.intentBytes == nil else {
            throw ManagedHistoryPersistenceError.verificationFailed
        }
        try BackupFile.removeMetadata(
            at: receiptURL, matching: persisted, maxBytes: ManagedHistoryErasureIntent.maxBytes
        )
        guard try !ManagedHistoryStartupFence.hasPending(in: root) else {
            throw ManagedHistoryPersistenceError.verificationFailed
        }
    }

    private static func clearRegistry(
        databaseURL: URL, intent: ManagedHistoryErasureIntent, now: Int64
    ) throws {
        let state = try inspect(databaseURL: databaseURL, intent: intent, now: now)
        guard !state.registry.entries.isEmpty else { return }
        guard state.intentBytes != nil, state.progressBytes != nil else {
            throw ManagedHistoryPersistenceError.incompleteInventory
        }
        let empty = try ManagedHistoryRegistry(entries: [])
        let url = databaseURL.deletingLastPathComponent().appendingPathComponent(ManagedHistoryRegistryFile.filename)
        try BackupFile.replaceMetadata(
            JSONEncoder().encode(empty), at: url, matching: state.registryBytes,
            maxBytes: ManagedHistoryRegistry.maxBytes
        )
    }

    private static func inspect(
        databaseURL: URL, intent: ManagedHistoryErasureIntent, now: Int64
    ) throws -> State {
        let root = databaseURL.deletingLastPathComponent()
        let intentBytes = try optionalBytes(
            root.appendingPathComponent(ManagedHistoryErasureIntentFile.filename),
            maxBytes: ManagedHistoryErasureIntent.maxBytes
        )
        if let intentBytes {
            guard try ManagedHistoryErasureIntent.decode(intentBytes) == intent else {
                throw ManagedHistoryPersistenceError.invalidIntent
            }
        }
        let progressBytes = try optionalBytes(
            root.appendingPathComponent(ManagedHistoryErasureProgressFile.filename),
            maxBytes: ManagedHistoryErasureProgressFile.maxBytes
        )
        if let progressBytes {
            let progress = try JSONDecoder().decode(ManagedHistoryErasureProgress.self, from: progressBytes)
            try progress.validate(intent: intent)
            guard intentBytes != nil, !progress.armed, progress.completedCount == intent.registry.entries.count else {
                throw ManagedHistoryPersistenceError.incompleteInventory
            }
        }
        let bytes = try BackupFile.load(
            root.appendingPathComponent(ManagedHistoryRegistryFile.filename), maxBytes: ManagedHistoryRegistry.maxBytes
        )
        let registry = try ManagedHistoryRegistry.decode(bytes)
        let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
        let session = try JournalV2Repository.inspectReadOnly(url: databaseURL, now: now)
        try verifyEmpty(session: session, inventory: inventory, intent: intent)
        guard registry.entries.isEmpty || (registry == intent.registry && intentBytes != nil && progressBytes != nil)
        else { throw ManagedHistoryPersistenceError.incompleteInventory }
        return State(intentBytes: intentBytes, progressBytes: progressBytes, registry: registry, registryBytes: bytes)
    }

    private static func verifyEmpty(
        session: JournalV2Session, inventory: ManagedHistoryInventory, intent: ManagedHistoryErasureIntent
    ) throws {
        guard session.version.epoch == intent.targetEpoch, session.version.revision == 0,
              session.catalog == WorkdayCatalog(), session.checkpoint == nil,
              inventory.items.allSatisfy({ $0.status == .missing })
        else { throw ManagedHistoryPersistenceError.incompleteInventory }
        switch (intent.directoryIdentity, inventory.directoryIdentity) {
        case (nil, nil): return
        case let (old?, current?) where old.device == current.device && old.inode == current.inode: return
        default: throw ManagedHistoryInventoryError.changedDirectory
        }
    }

    private static func optionalBytes(_ url: URL, maxBytes: Int) throws -> Data? {
        do {
            return try BackupFile.load(url, maxBytes: maxBytes)
        } catch let BackupFileError.system(code) {
            // ENOENT from opening the leaf is allowed only after a private
            // root was already established by the caller; dangling links
            // are rejected by O_NOFOLLOW.
            guard code == ENOENT else { throw BackupFileError.system(code) }
            return nil
        }
    }
}
