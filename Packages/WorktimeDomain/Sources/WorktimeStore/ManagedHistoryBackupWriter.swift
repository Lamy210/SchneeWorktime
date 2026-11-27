import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// App-owned backup production, never adoption of a user-selected file.
/// Caller owns the private root and exclusive session lock. No UI connection.
/// A failure after publication deliberately leaves the file unregistered.
enum ManagedHistoryBackupWriter {
    static func publish(
        _ data: Data, epoch: UUID, in root: URL
    ) throws -> ManagedHistoryEntry {
        guard try !ManagedHistoryStartupFence.hasPending(in: root) else {
            throw ManagedHistoryPersistenceError.pendingIntent
        }
        let registryURL = root.appendingPathComponent(ManagedHistoryRegistryFile.filename)
        let original = try BackupFile.load(registryURL, maxBytes: ManagedHistoryRegistry.maxBytes)
        let registry = try ManagedHistoryRegistry.decode(original)
        let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
        guard inventory.isComplete, inventory.directoryIdentity != nil,
              registry.entries.count < ManagedHistoryRegistry.maxEntries
        else { throw ManagedHistoryPersistenceError.incompleteInventory }

        let id = UUID()
        let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName, isDirectory: true)
        let file = directory.appendingPathComponent("backup-\(id.uuidString).json")
        try BackupFile.publish(data, to: file, maxBytes: JournalV2Backup.maxBytes)
        let entry = try verifiedEntry(file: file, id: id, epoch: epoch, data: data)
        let next = try ManagedHistoryRegistry(entries: registry.entries + [entry])
        let after = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: next)
        guard after.isComplete, sameDirectory(inventory, after),
              try !ManagedHistoryStartupFence.hasPending(in: root)
        else { throw ManagedHistoryPersistenceError.incompleteInventory }
        let encoded = try JSONEncoder().encode(next)
        try BackupFile.replaceMetadata(
            encoded, at: registryURL, matching: original, maxBytes: ManagedHistoryRegistry.maxBytes
        )
        guard try ManagedHistoryRegistryFile.load(in: root) == next,
              try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: next) == after
        else { throw ManagedHistoryPersistenceError.verificationFailed }
        return entry
    }

    private static func verifiedEntry(
        file: URL, id: UUID, epoch: UUID, data: Data
    ) throws -> ManagedHistoryEntry {
        let identity = try fileIdentity(file)
        guard try BackupFile.load(file, maxBytes: JournalV2Backup.maxBytes) == data,
              try fileIdentity(file) == identity
        else { throw ManagedHistoryPersistenceError.verificationFailed }
        return ManagedHistoryEntry(id: id, kind: .backup, epoch: epoch, identity: identity)
    }

    private static func fileIdentity(_ url: URL) throws -> ManagedHistoryFileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ManagedHistoryInventoryError.system(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0
        else { throw BackupFileError.unsafeFile }
        return ManagedHistoryFileIdentity(info)
    }

    private static func sameDirectory(_ before: ManagedHistoryInventory, _ after: ManagedHistoryInventory) -> Bool {
        guard let old = before.directoryIdentity, let new = after.directoryIdentity else { return false }
        return old.device == new.device && old.inode == new.inode
    }
}
