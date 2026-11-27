import Foundation
import Testing
@testable import WorktimeStore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct ManagedHistoryInventoryTests {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managed = root.appendingPathComponent(ManagedHistoryInventory.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: managed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        try body(root, managed)
    }

    private func entry(in directory: URL, kind: ManagedHistoryKind = .backup) throws -> ManagedHistoryEntry {
        let id = UUID()
        let name = "\(kind.rawValue)-\(id.uuidString).json"
        let file = directory.appendingPathComponent(name)
        try Data("synthetic".utf8).write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw ManagedHistoryInventoryError.system(errno) }
        return ManagedHistoryEntry(id: id, kind: kind, epoch: UUID(), identity: ManagedHistoryFileIdentity(info))
    }

    @Test func `registered files are verified but lookalike and external files are not adopted`() throws {
        try fixture { root, managed in
            let known = try entry(in: managed)
            let unknown = try entry(in: managed, kind: .diagnostic)
            let outside = root.appendingPathComponent(known.name)
            try Data("external".utf8).write(to: outside)
            let registry = try ManagedHistoryRegistry(entries: [known])
            let decoded = try ManagedHistoryRegistry.decode(JSONEncoder().encode(registry))
            #expect(decoded == registry)
            let result = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: decoded)
            #expect(result.items.count == 2)
            #expect(result.items.first { $0.name == known.name }?.status == .verified)
            #expect(result.items.first { $0.name == unknown.name }?.status == .unregistered)
            #expect(!result.isComplete)
            #expect(try Data(contentsOf: outside) == Data("external".utf8))
            #expect(FileManager.default.fileExists(atPath: managed.appendingPathComponent(unknown.name).path))
        }
    }

    @Test func `replacement missing and linked files are never verified`() throws {
        try fixture { root, managed in
            let replaced = try entry(in: managed)
            let missing = try entry(in: managed)
            let linked = try entry(in: managed)
            let symbolic = try entry(in: managed)
            let outside = root.appendingPathComponent("external.json")
            try Data("external".utf8).write(to: outside)
            let destination = managed.appendingPathComponent(replaced.name)
            let previous = root.appendingPathComponent("preserved.json")
            try FileManager.default.moveItem(at: destination, to: previous)
            try Data("different".utf8).write(to: destination)
            #expect(chmod(destination.path, 0o600) == 0)
            try FileManager.default.removeItem(at: managed.appendingPathComponent(missing.name))
            try FileManager.default.linkItem(
                at: managed.appendingPathComponent(linked.name), to: root.appendingPathComponent("hardlink")
            )
            try FileManager.default.removeItem(at: managed.appendingPathComponent(symbolic.name))
            try FileManager.default.createSymbolicLink(
                at: managed.appendingPathComponent(symbolic.name), withDestinationURL: outside
            )
            let registry = try ManagedHistoryRegistry(entries: [replaced, missing, linked, symbolic])
            let result = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            #expect(result.items.first { $0.name == replaced.name }?.status == .changed)
            #expect(result.items.first { $0.name == missing.name }?.status == .missing)
            #expect(result.items.first { $0.name == linked.name }?.status == .unsafe)
            #expect(result.items.first { $0.name == symbolic.name }?.status == .unsafe)
            #expect(!result.isComplete)
            #expect(try Data(contentsOf: outside) == Data("external".utf8))
        }
    }

    @Test func `private directory is required and missing root does not create a directory`() throws {
        try fixture { root, managed in
            let known = try entry(in: managed)
            let registry = try ManagedHistoryRegistry(entries: [known])
            #expect(throws: ManagedHistoryInventoryError.invalidRegistry) {
                try ManagedHistoryRegistry(entries: [known, known])
            }
            let complete = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            #expect(complete.isComplete)
            #expect(chmod(managed.path, 0o755) == 0)
            #expect(throws: ManagedHistoryInventoryError.unsafeDirectory) {
                try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            }
            try FileManager.default.moveItem(at: managed, to: root.appendingPathComponent("preserved"))
            let absent = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            #expect(absent.items.first?.status == .missing)
            #expect(!absent.isComplete)
            #expect(!FileManager.default.fileExists(atPath: managed.path))
        }
    }

    @Test func `a symlink at managed directory cannot expose external inventory`() throws {
        try fixture { root, managed in
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.moveItem(at: managed, to: outside)
            let known = try entry(in: outside)
            try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
            let registry = try ManagedHistoryRegistry(entries: [known])
            #expect(throws: ManagedHistoryInventoryError.self) {
                try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
            }
            #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent(known.name).path))
        }
    }
}
