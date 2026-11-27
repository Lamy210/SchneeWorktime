import Foundation
import WorktimeDomain

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

enum ManagedHistoryPersistenceError: Error, Equatable {
    case verificationFailed, invalidIntent, incompleteInventory, pendingIntent
}

/// Immutable publication only. Missing or malformed registries are not treated
/// as empty. Replacement and trusted registration are separate operations.
/// Caller owns the private application directory and session lock.
enum ManagedHistoryRegistryFile {
    static let filename = "managed-history-registry-v1.json"

    static func publishInitial(_ registry: ManagedHistoryRegistry, in directory: URL) throws {
        try registry.validate()
        let data = try JSONEncoder().encode(registry)
        let url = directory.appendingPathComponent(filename)
        try BackupFile.publish(data, to: url, maxBytes: ManagedHistoryRegistry.maxBytes)
        guard try load(in: directory) == registry else {
            throw ManagedHistoryPersistenceError.verificationFailed
        }
    }

    static func load(in directory: URL) throws -> ManagedHistoryRegistry {
        let data = try BackupFile.load(
            directory.appendingPathComponent(filename), maxBytes: ManagedHistoryRegistry.maxBytes
        )
        return try ManagedHistoryRegistry.decode(data)
    }
}

enum ManagedHistoryRecoveryAssessment: Equatable {
    case needsNewConfirmation
    case pendingFiles([String])
    case needsCompletionVerification
    case blocked
}

/// Read-only recovery classification, never authorization to unlink files.
/// An intent binds a complete registered inventory and a planned new epoch.
/// No caller may infer reset success merely because the old epoch changed.
struct ManagedHistoryErasureIntent: Codable, Equatable {
    static let maxBytes = ManagedHistoryRegistry.maxBytes + 4096
    let schema: Int
    let id: UUID
    let sourceEpoch: UUID
    let sourceRevision: Int64
    let targetEpoch: UUID
    let registry: ManagedHistoryRegistry
    let directoryIdentity: ManagedHistoryFileIdentity?

    init(source: StoreVersion, registry: ManagedHistoryRegistry, inventory: ManagedHistoryInventory) throws {
        try registry.validate()
        guard inventory.isComplete, Self.matchesEntries(inventory, registry: registry),
              registry.entries.isEmpty || inventory.directoryIdentity != nil
        else { throw ManagedHistoryPersistenceError.incompleteInventory }
        schema = 1
        id = UUID()
        sourceEpoch = source.epoch
        sourceRevision = source.revision
        targetEpoch = UUID()
        self.registry = registry
        directoryIdentity = inventory.directoryIdentity
        try validate()
    }

    func validate() throws {
        try registry.validate()
        guard schema == 1, sourceEpoch != targetEpoch, sourceRevision >= 0,
              registry.entries.isEmpty || directoryIdentity != nil
        else { throw ManagedHistoryPersistenceError.invalidIntent }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxBytes else { throw ManagedHistoryPersistenceError.invalidIntent }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    /// Use a validated read-only repository session. The pure classifier
    /// below is also exercised by synthetic interruption tests.
    func assess(
        session: JournalV2Session, registry: ManagedHistoryRegistry, inventory: ManagedHistoryInventory
    ) -> ManagedHistoryRecoveryAssessment {
        assess(
            version: session.version, empty: session.catalog == WorkdayCatalog() && session.checkpoint == nil,
            registry: registry, inventory: inventory
        )
    }

    /// Missing files are only classified as potentially completed after the
    /// *planned* empty generation exists. Even then, a separate coordinator
    /// must check durable per-file progress, notifications and final state.
    func assess(
        version: StoreVersion, empty: Bool, registry: ManagedHistoryRegistry, inventory: ManagedHistoryInventory
    ) -> ManagedHistoryRecoveryAssessment {
        guard (try? validate()) != nil, self.registry == registry,
              Self.matchesEntries(inventory, registry: registry),
              sameDirectory(inventory.directoryIdentity)
        else { return .blocked }
        if version.epoch == sourceEpoch, version.revision == sourceRevision {
            return inventory.isComplete && directoryIdentity == inventory.directoryIdentity
                ? .needsNewConfirmation : .blocked
        }
        guard version.epoch == targetEpoch, version.revision == 0, empty,
              inventory.items.allSatisfy({ $0.status == .verified || $0.status == .missing })
        else { return .blocked }
        let remaining = inventory.items.filter { $0.status == .verified }.map(\.name).sorted()
        return remaining.isEmpty ? .needsCompletionVerification : .pendingFiles(remaining)
    }

    private func sameDirectory(_ current: ManagedHistoryFileIdentity?) -> Bool {
        switch (directoryIdentity, current) {
        case (nil, nil): true
        case let (original?, actual?): original.device == actual.device && original.inode == actual.inode
        default: false
        }
    }

    private static func matchesEntries(
        _ inventory: ManagedHistoryInventory, registry: ManagedHistoryRegistry
    ) -> Bool {
        let expected = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.name, $0) })
        guard inventory.items.count == expected.count,
              Set(inventory.items.map(\.name)).count == expected.count
        else { return false }
        return inventory.items.allSatisfy { item in
            guard let entry = expected[item.name] else { return false }
            return item.entry == entry
        }
    }
}

/// One outstanding intent per private application root. No overwrite, no
/// automatic retry after uncertain publication, and no implicit clearing.
enum ManagedHistoryErasureIntentFile {
    static let filename = "managed-history-erasure-v1.json"

    static func publish(_ intent: ManagedHistoryErasureIntent, in directory: URL) throws {
        try intent.validate()
        let registry = try ManagedHistoryRegistryFile.load(in: directory)
        let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: directory, registry: registry)
        guard intent.registry == registry,
              intent.assess(
                  version: StoreVersion(epoch: intent.sourceEpoch, revision: intent.sourceRevision),
                  empty: false, registry: registry, inventory: inventory
              ) == .needsNewConfirmation
        else { throw ManagedHistoryPersistenceError.incompleteInventory }
        let data = try JSONEncoder().encode(intent)
        try BackupFile.publish(
            data, to: directory.appendingPathComponent(filename), maxBytes: ManagedHistoryErasureIntent.maxBytes
        )
        guard try load(in: directory) == intent else {
            throw ManagedHistoryPersistenceError.verificationFailed
        }
    }

    static func load(in directory: URL) throws -> ManagedHistoryErasureIntent {
        let data = try BackupFile.load(
            directory.appendingPathComponent(filename), maxBytes: ManagedHistoryErasureIntent.maxBytes
        )
        return try ManagedHistoryErasureIntent.decode(data)
    }
}

/// Presence, not successful decoding, is the startup fence. A malformed
/// marker or dangling symlink also blocks; permission/I/O errors fail closed.
/// No marker is automatically removed. Missing application roots are allowed.
package enum ManagedHistoryStartupFence {
    package static func hasPending(in directory: URL) throws -> Bool {
        guard directory.isFileURL else { throw ManagedHistoryInventoryError.unsafeDirectory }
        let path = directory.appendingPathComponent(ManagedHistoryErasureIntentFile.filename).path
        var info = stat()
        if lstat(path, &info) == 0 {
            return true
        }
        let code = errno
        guard code == ENOENT else { throw ManagedHistoryInventoryError.system(code) }
        return false
    }
}
