import Foundation
import Testing
@testable import WorktimeStore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct ManagedHistoryErasureIntentTests {
    private func fixture(_ body: (URL, ManagedHistoryRegistry) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let id = UUID()
        let file = directory.appendingPathComponent("backup-\(id.uuidString).json")
        try Data("synthetic".utf8).write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw ManagedHistoryInventoryError.system(errno) }
        let entry = ManagedHistoryEntry(
            id: id, kind: .backup, epoch: UUID(), identity: ManagedHistoryFileIdentity(info)
        )
        try body(root, ManagedHistoryRegistry(entries: [entry]))
    }

    @Test func `registry and intent survive reload and cannot overwrite existing records`() throws {
        try fixture { root, registry in
            try ManagedHistoryRegistryFile.publishInitial(registry, in: root)
            #expect(try ManagedHistoryRegistryFile.load(in: root) == registry)
            #expect(throws: BackupFileError.self) {
                try ManagedHistoryRegistryFile.publishInitial(ManagedHistoryRegistry(entries: []), in: root)
            }
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            let source = StoreVersion(epoch: UUID(), revision: 3)
            let intent = try ManagedHistoryErasureIntent(source: source, registry: registry, inventory: inventory)
            try ManagedHistoryErasureIntentFile.publish(intent, in: root)
            #expect(try ManagedHistoryErasureIntentFile.load(in: root) == intent)
            #expect(throws: BackupFileError.self) {
                try ManagedHistoryErasureIntentFile.publish(intent, in: root)
            }
            #expect(try ManagedHistoryErasureIntentFile.load(in: root) == intent)
            #expect(try ManagedHistoryRegistryFile.load(in: root) == registry)
        }
    }

    @Test func `only the planned empty generation can classify remaining managed files`() throws {
        try fixture { root, registry in
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            let source = StoreVersion(epoch: UUID(), revision: 3)
            let intent = try ManagedHistoryErasureIntent(source: source, registry: registry, inventory: inventory)
            let name = try #require(registry.entries.first).name
            let target = StoreVersion(epoch: intent.targetEpoch, revision: 0)
            let unrelated = StoreVersion(epoch: UUID(), revision: 0)
            #expect(intent.assess(
                version: source, empty: false, registry: registry, inventory: inventory
            ) == .needsNewConfirmation)
            #expect(intent.assess(
                version: unrelated, empty: true, registry: registry, inventory: inventory
            ) == .blocked)
            #expect(intent.assess(
                version: target, empty: false, registry: registry, inventory: inventory
            ) == .blocked)
            #expect(intent.assess(
                version: target, empty: true, registry: registry, inventory: inventory
            ) == .pendingFiles([name]))
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            let missing = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            #expect(intent.assess(
                version: source, empty: false, registry: registry, inventory: missing
            ) == .blocked)
            #expect(intent.assess(
                version: target, empty: true, registry: registry, inventory: missing
            ) == .needsCompletionVerification)
            #expect(intent.assess(
                version: target, empty: true, registry: registry, inventory: missing
            ) == .needsCompletionVerification)
        }
    }

    @Test func `unregistered files and replacement root block publication or recovery`() throws {
        try fixture { root, registry in
            try ManagedHistoryRegistryFile.publishInitial(registry, in: root)
            let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            let intent = try ManagedHistoryErasureIntent(
                source: StoreVersion(epoch: UUID(), revision: 3), registry: registry, inventory: inventory
            )
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let unknown = directory.appendingPathComponent("unregistered.json")
            try Data("not owned".utf8).write(to: unknown)
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try ManagedHistoryErasureIntentFile.publish(intent, in: root)
            }
            let changed = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            let target = StoreVersion(epoch: intent.targetEpoch, revision: 0)
            #expect(intent.assess(
                version: target, empty: true, registry: registry, inventory: changed
            ) == .blocked)
            #expect(try Data(contentsOf: unknown) == Data("not owned".utf8))
            try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("preserved"))
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            let replaced = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            #expect(intent.assess(
                version: target, empty: true, registry: registry, inventory: replaced
            ) == .blocked)
        }
    }

    @Test func `missing malformed and linked metadata never load as empty registries`() throws {
        try fixture { root, registry in
            #expect(throws: BackupFileError.self) { try ManagedHistoryRegistryFile.load(in: root) }
            try ManagedHistoryRegistryFile.publishInitial(registry, in: root)
            let file = root.appendingPathComponent(ManagedHistoryRegistryFile.filename)
            let other = root.appendingPathComponent("other.json")
            try FileManager.default.linkItem(at: file, to: other)
            #expect(throws: BackupFileError.self) { try ManagedHistoryRegistryFile.load(in: root) }
            try FileManager.default.removeItem(at: other)
            try Data("malformed".utf8).write(to: file)
            #expect(throws: DecodingError.self) { try ManagedHistoryRegistryFile.load(in: root) }
        }
    }
}
