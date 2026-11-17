import Foundation
import Testing
@testable import WorktimeStore

struct BackupFileTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func `complete archive is published privately and round trips`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("backup.json")
            let data = Data(repeating: 42, count: 150_000)
            try BackupFile.publish(data, to: url)
            #expect(try BackupFile.load(url) == data)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["backup.json"])
        }
    }

    @Test func `existing destination remains untouched and temporary file is removed`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("backup.json")
            let original = Data([1])
            try BackupFile.publish(original, to: url)
            #expect(throws: BackupFileError.self) {
                try BackupFile.publish(Data([2]), to: url)
            }
            #expect(try BackupFile.load(url) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["backup.json"])
        }
    }

    @Test func `symlink destination is neither followed nor overwritten`() throws {
        try withDirectory { root in
            let target = root.appendingPathComponent("target")
            let link = root.appendingPathComponent("backup.json")
            try BackupFile.publish(Data([1]), to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: BackupFileError.self) { try BackupFile.load(link) }
            #expect(throws: BackupFileError.self) { try BackupFile.publish(Data([2]), to: link) }
            #expect(try BackupFile.load(target) == Data([1]))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        }
    }

    @Test func `public destination directory is refused`() throws {
        try withDirectory { root in
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            let url = root.appendingPathComponent("backup.json")
            #expect(throws: BackupFileError.unsafeDirectory) { try BackupFile.publish(Data([1]), to: url) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func `oversized archive is rejected before publication and on read`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("backup.json")
            let large = Data(count: BackupFile.maxBytes + 1)
            #expect(throws: BackupFileError.tooLarge) { try BackupFile.publish(large, to: url) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
            try large.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #expect(throws: BackupFileError.tooLarge) { try BackupFile.load(url) }
        }
    }

    @Test func `insecure files and hard links are rejected`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("backup.json")
            try BackupFile.publish(Data([1]), to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(throws: BackupFileError.unsafeFile) { try BackupFile.load(url) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try FileManager.default.linkItem(at: url, to: root.appendingPathComponent("hardlink"))
            #expect(throws: BackupFileError.unsafeFile) { try BackupFile.load(url) }
        }
    }
}
