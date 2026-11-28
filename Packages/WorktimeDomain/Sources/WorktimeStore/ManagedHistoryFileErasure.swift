import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A deterministic prefix of the immutable intent's sorted entries. At most
/// one file is armed before unlink; an unexplained missing file blocks.
struct ManagedHistoryErasureProgress: Codable, Equatable {
    let schema: Int
    let intentID: UUID
    let targetEpoch: UUID
    let completedCount: Int
    let armed: Bool

    init(intent: ManagedHistoryErasureIntent, completedCount: Int = 0, armed: Bool = false) {
        schema = 1
        intentID = intent.id
        targetEpoch = intent.targetEpoch
        self.completedCount = completedCount
        self.armed = armed
    }

    func validate(intent: ManagedHistoryErasureIntent) throws {
        guard schema == 1, intentID == intent.id, targetEpoch == intent.targetEpoch,
              (0 ... intent.registry.entries.count).contains(completedCount),
              !armed || completedCount < intent.registry.entries.count
        else { throw ManagedHistoryPersistenceError.invalidIntent }
    }

    func permits(_ inventory: ManagedHistoryInventory, intent: ManagedHistoryErasureIntent) -> Bool {
        guard (try? validate(intent: intent)) != nil else { return false }
        let entries = intent.registry.entries.sorted { $0.name < $1.name }
        let items = inventory.items.sorted { $0.name < $1.name }
        guard entries.count == items.count else { return false }
        return zip(entries, items).enumerated().allSatisfy { index, pair in
            let (entry, item) = pair
            guard item.name == entry.name, item.entry == entry else { return false }
            if index < completedCount {
                return item.status == .missing
            }
            if index == completedCount, armed {
                return item.status == .verified || item.status == .missing
            }
            return item.status == .verified
        }
    }
}

enum ManagedHistoryErasureProgressFile {
    static let filename = "managed-history-erasure-progress-v1.json"
    static let maxBytes = 4096

    static func load(
        in root: URL, intent: ManagedHistoryErasureIntent
    ) throws -> (progress: ManagedHistoryErasureProgress, bytes: Data) {
        let bytes = try BackupFile.load(root.appendingPathComponent(filename), maxBytes: maxBytes)
        let progress = try JSONDecoder().decode(ManagedHistoryErasureProgress.self, from: bytes)
        try progress.validate(intent: intent)
        return (progress, bytes)
    }

    static func publish(_ progress: ManagedHistoryErasureProgress, in root: URL) throws {
        let bytes = try JSONEncoder().encode(progress)
        try BackupFile.publish(bytes, to: root.appendingPathComponent(filename), maxBytes: maxBytes)
    }

    static func replace(
        _ next: ManagedHistoryErasureProgress, in root: URL, matching bytes: Data
    ) throws {
        try BackupFile.replaceMetadata(
            JSONEncoder().encode(next), at: root.appendingPathComponent(filename),
            matching: bytes, maxBytes: maxBytes
        )
    }
}

enum ManagedHistoryErasureStep: Equatable {
    case advanced(completed: Int, total: Int)
    case needsCompletionVerification
}

/// Internal maintenance API. The caller must hold the exclusive application
/// lock, stop notifications/writers, and obtain explicit confirmation.
/// No startup path invokes it automatically, and it never clears the fence.
enum ManagedHistoryFileErasure {
    static func initialize(databaseURL: URL, intent: ManagedHistoryErasureIntent, now: Int64) throws {
        let root = databaseURL.deletingLastPathComponent()
        let inventory = try inspect(databaseURL: databaseURL, intent: intent, now: now)
        let progress = ManagedHistoryErasureProgress(intent: intent)
        guard progress.permits(inventory, intent: intent) else {
            throw ManagedHistoryPersistenceError.incompleteInventory
        }
        try ManagedHistoryErasureProgressFile.publish(progress, in: root)
        guard try ManagedHistoryErasureProgressFile.load(in: root, intent: intent).progress == progress else {
            throw ManagedHistoryPersistenceError.verificationFailed
        }
    }

    static func advance(
        databaseURL: URL, intent: ManagedHistoryErasureIntent, now: Int64,
        afterUnlink: () throws -> Void = {}
    ) throws -> ManagedHistoryErasureStep {
        let root = databaseURL.deletingLastPathComponent()
        let inventory = try inspect(databaseURL: databaseURL, intent: intent, now: now)
        var loaded = try ManagedHistoryErasureProgressFile.load(in: root, intent: intent)
        guard loaded.progress.permits(inventory, intent: intent) else {
            throw ManagedHistoryPersistenceError.incompleteInventory
        }
        let count = loaded.progress.completedCount
        let entries = intent.registry.entries.sorted { $0.name < $1.name }
        guard count < entries.count else { return .needsCompletionVerification }
        if !loaded.progress.armed {
            let armed = ManagedHistoryErasureProgress(intent: intent, completedCount: count, armed: true)
            try ManagedHistoryErasureProgressFile.replace(armed, in: root, matching: loaded.bytes)
            loaded = try ManagedHistoryErasureProgressFile.load(in: root, intent: intent)
            guard loaded.progress == armed else { throw ManagedHistoryPersistenceError.verificationFailed }
        }
        let current = try inspect(databaseURL: databaseURL, intent: intent, now: now)
        guard loaded.progress.permits(current, intent: intent) else {
            throw ManagedHistoryPersistenceError.incompleteInventory
        }
        try removeArmed(entries[count], in: root, intent: intent)
        try afterUnlink()
        let next = ManagedHistoryErasureProgress(intent: intent, completedCount: count + 1)
        let after = try inspect(databaseURL: databaseURL, intent: intent, now: now)
        guard next.permits(after, intent: intent) else {
            throw ManagedHistoryPersistenceError.incompleteInventory
        }
        try ManagedHistoryErasureProgressFile.replace(next, in: root, matching: loaded.bytes)
        guard try ManagedHistoryErasureProgressFile.load(in: root, intent: intent).progress == next else {
            throw ManagedHistoryPersistenceError.verificationFailed
        }
        return .advanced(completed: count + 1, total: entries.count)
    }

    private static func inspect(
        databaseURL: URL, intent: ManagedHistoryErasureIntent, now: Int64
    ) throws -> ManagedHistoryInventory {
        let root = databaseURL.deletingLastPathComponent()
        guard try ManagedHistoryErasureIntentFile.load(in: root) == intent else {
            throw ManagedHistoryPersistenceError.invalidIntent
        }
        let registry = try ManagedHistoryRegistryFile.load(in: root)
        let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
        let session = try JournalV2Repository.inspectReadOnly(url: databaseURL, now: now)
        switch intent.assess(session: session, registry: registry, inventory: inventory) {
        case .pendingFiles, .needsCompletionVerification: return inventory
        case .needsNewConfirmation, .blocked: throw ManagedHistoryPersistenceError.incompleteInventory
        }
    }

    private static func removeArmed(
        _ entry: ManagedHistoryEntry, in root: URL, intent: ManagedHistoryErasureIntent
    ) throws {
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ManagedHistoryInventoryError.system(errno) }
        defer { close(parent) }
        _ = try privateDirectory(parent)
        let name = ManagedHistoryInventory.directoryName
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ManagedHistoryInventoryError.system(errno) }
        defer { close(directory) }
        let identity = try privateDirectory(directory)
        guard let expected = intent.directoryIdentity,
              identity.device == expected.device, identity.inode == expected.inode
        else { throw ManagedHistoryInventoryError.changedDirectory }
        try unlinkVerified(entry, directory: directory)
        // Also synchronize a resumed armed-but-missing entry before recording
        // its completion. A failed fsync leaves the durable armed state.
        while fsync(directory) != 0 {
            let code = errno
            guard code == EINTR else { throw ManagedHistoryInventoryError.system(code) }
        }
    }

    private static func privateDirectory(_ fd: Int32) throws -> ManagedHistoryFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ManagedHistoryInventoryError.system(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else { throw ManagedHistoryInventoryError.unsafeDirectory }
        return ManagedHistoryFileIdentity(info)
    }

    private static func unlinkVerified(_ entry: ManagedHistoryEntry, directory: Int32) throws {
        var info = stat()
        if fstatat(directory, entry.name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            let code = errno
            guard code == ENOENT else { throw ManagedHistoryInventoryError.system(code) }
            return
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0,
              ManagedHistoryFileIdentity(info) == entry.identity
        else { throw ManagedHistoryPersistenceError.verificationFailed }
        guard unlinkat(directory, entry.name, 0) == 0 else {
            throw ManagedHistoryInventoryError.system(errno)
        }
    }
}
