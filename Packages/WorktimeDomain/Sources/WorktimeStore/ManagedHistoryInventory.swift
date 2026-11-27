import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

enum ManagedHistoryInventoryError: Error, Equatable {
    case invalidRegistry, unsafeDirectory, system(Int32), changedDirectory
}

enum ManagedHistoryKind: String, Codable, Equatable {
    case backup, diagnostic
}

/// Only the dedicated flat namespace is eligible. Neither arbitrary paths
/// nor legacy recovery/staging directories are inferred to be app-owned.
struct ManagedHistoryEntry: Codable, Equatable {
    let id: UUID
    let kind: ManagedHistoryKind
    let epoch: UUID
    let identity: ManagedHistoryFileIdentity

    var name: String {
        "\(kind.rawValue)-\(id.uuidString).json"
    }
}

/// Metadata fence, not a proof of byte equality or protection against the
/// same uid. A later destructive operation must revalidate under the owner lock.
struct ManagedHistoryFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ info: stat) {
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(info.st_ino)
        bytes = Int64(info.st_size)
        #if canImport(Darwin)
            let modified = info.st_mtimespec
            let changed = info.st_ctimespec
        #else
            let modified = info.st_mtim
            let changed = info.st_ctim
        #endif
        modifiedSeconds = Int64(modified.tv_sec)
        modifiedNanoseconds = Int64(modified.tv_nsec)
        changedSeconds = Int64(changed.tv_sec)
        changedNanoseconds = Int64(changed.tv_nsec)
    }
}

/// The registry must originate from a trusted producer, not from scanning
/// names. This format is preparatory: no runtime producer writes it yet.
struct ManagedHistoryRegistry: Codable, Equatable {
    static let maxEntries = 10000
    static let maxBytes = 4 * 1024 * 1024
    let schema: Int
    let entries: [ManagedHistoryEntry]

    init(entries: [ManagedHistoryEntry]) throws {
        schema = 1
        self.entries = entries
        try validate()
    }

    func validate() throws {
        guard schema == 1, entries.count <= Self.maxEntries,
              Set(entries.map(\.name)).count == entries.count,
              entries.allSatisfy({ $0.identity.bytes >= 0 })
        else { throw ManagedHistoryInventoryError.invalidRegistry }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxBytes else { throw ManagedHistoryInventoryError.invalidRegistry }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}

enum ManagedHistoryEntryStatus: Equatable {
    case verified, missing, changed, unsafe, unregistered
}

struct ManagedHistoryInventoryItem: Equatable {
    let name: String
    let entry: ManagedHistoryEntry?
    let status: ManagedHistoryEntryStatus
}

struct ManagedHistoryInventory: Equatable {
    static let directoryName = "managed-history-v1"
    let directoryIdentity: ManagedHistoryFileIdentity?
    let items: [ManagedHistoryInventoryItem]

    /// A fresh deletion plan requires complete agreement; a missing entry
    /// is not interpreted as completed deletion outside a durable intent.
    var isComplete: Bool {
        items.allSatisfy { $0.status == .verified }
    }
}

enum ManagedHistoryInventoryReader {
    /// Read only. The caller owns the private application directory and
    /// session lock. No registry, directory or file is created or adopted.
    static func inspect(applicationDirectory: URL, registry: ManagedHistoryRegistry) throws -> ManagedHistoryInventory {
        try registry.validate()
        guard applicationDirectory.isFileURL else { throw ManagedHistoryInventoryError.unsafeDirectory }
        let parent = open(applicationDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ManagedHistoryInventoryError.system(errno) }
        defer { close(parent) }
        let parentIdentity = try privateDirectory(parent)
        let name = ManagedHistoryInventory.directoryName
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            let code = errno
            guard code == ENOENT else { throw ManagedHistoryInventoryError.system(code) }
            try verifyParent(applicationDirectory, fd: parent, expected: parentIdentity)
            return ManagedHistoryInventory(directoryIdentity: nil, items: registry.entries.map {
                ManagedHistoryInventoryItem(name: $0.name, entry: $0, status: .missing)
            }.sorted { $0.name < $1.name })
        }
        defer { close(directory) }
        let identity = try privateDirectory(directory)
        let url = applicationDirectory.appendingPathComponent(name, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard names.count <= ManagedHistoryRegistry.maxEntries else {
            throw ManagedHistoryInventoryError.invalidRegistry
        }
        let items = try classify(names: names, registry: registry, directory: directory)
        guard try privateDirectory(directory) == identity,
              try currentDirectory(parent: parent, name: name) == identity
        else { throw ManagedHistoryInventoryError.changedDirectory }
        try verifyParent(applicationDirectory, fd: parent, expected: parentIdentity)
        return ManagedHistoryInventory(directoryIdentity: identity, items: items)
    }

    private static func verifyParent(
        _ url: URL, fd: Int32, expected: ManagedHistoryFileIdentity
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ManagedHistoryInventoryError.system(errno) }
        guard try directoryIdentity(info) == expected, try privateDirectory(fd) == expected else {
            throw ManagedHistoryInventoryError.changedDirectory
        }
    }

    private static func privateDirectory(_ fd: Int32) throws -> ManagedHistoryFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ManagedHistoryInventoryError.system(errno) }
        return try directoryIdentity(info)
    }

    private static func currentDirectory(parent: Int32, name: String) throws -> ManagedHistoryFileIdentity {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ManagedHistoryInventoryError.system(errno)
        }
        return try directoryIdentity(info)
    }

    private static func directoryIdentity(_ info: stat) throws -> ManagedHistoryFileIdentity {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else { throw ManagedHistoryInventoryError.unsafeDirectory }
        return ManagedHistoryFileIdentity(info)
    }

    private static func classify(
        names: [String], registry: ManagedHistoryRegistry, directory: Int32
    ) throws -> [ManagedHistoryInventoryItem] {
        let registered = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.name, $0) })
        let allNames = Set(names).union(registered.keys).sorted()
        return try allNames.map { name in
            guard let entry = registered[name] else {
                return ManagedHistoryInventoryItem(name: name, entry: nil, status: .unregistered)
            }
            let status = try Self.status(of: entry, directory: directory)
            return ManagedHistoryInventoryItem(name: name, entry: entry, status: status)
        }
    }

    private static func status(of entry: ManagedHistoryEntry, directory: Int32) throws -> ManagedHistoryEntryStatus {
        var info = stat()
        guard fstatat(directory, entry.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            guard code == ENOENT else { throw ManagedHistoryInventoryError.system(code) }
            return .missing
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0
        else { return .unsafe }
        return ManagedHistoryFileIdentity(info) == entry.identity ? .verified : .changed
    }
}
