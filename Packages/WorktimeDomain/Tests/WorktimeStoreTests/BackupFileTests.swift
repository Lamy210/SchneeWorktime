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

    @Test func `directory sync failure is reported without discarding the published backup`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("backup.json")
            let original = Data([1, 2, 3])
            let failure = BackupFileError.publicationUncertain(5)
            var synchronized = false
            do {
                try BackupFile.publish(original, to: url, synchronizeDirectory: { _ in
                    let published = try BackupFile.load(url)
                    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    synchronized = published == original && names == ["backup.json"]
                    throw failure
                })
                Issue.record("Expected directory synchronization failure")
            } catch let error as BackupFileError {
                #expect(error == failure)
            }
            #expect(synchronized)
            #expect(try BackupFile.load(url) == original)
            #expect(throws: BackupFileError.self) {
                try BackupFile.publish(Data([9]), to: url)
            }
            #expect(try BackupFile.load(url) == original)
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

    @Test func `schema two permits files above legacy limit without changing legacy readers`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("large.json")
            let data = Data(repeating: 0x36, count: BackupFile.maxBytes + 1)
            #expect(throws: BackupFileError.tooLarge) {
                try BackupFile.publish(data, to: url)
            }
            try BackupFile.publish(data, to: url, maxBytes: JournalV2Backup.maxBytes)
            #expect(throws: BackupFileError.tooLarge) {
                try BackupFile.load(url)
            }
            #expect(try BackupFile.load(url, maxBytes: JournalV2Backup.maxBytes) == data)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            #expect(throws: BackupFileError.self) {
                try BackupFile.publish(data, to: url, maxBytes: JournalV2Backup.maxBytes)
            }
            #expect(try BackupFile.load(url, maxBytes: JournalV2Backup.maxBytes) == data)
        }
    }

    @Test func `schema two hard limit rejects oversized file metadata before allocation`() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("oversized.json")
            try Data().write(to: url)
            let writer = try FileHandle(forWritingTo: url)
            try writer.truncate(atOffset: UInt64(JournalV2Backup.maxBytes + 1))
            try writer.close()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
            #expect(throws: BackupFileError.tooLarge) {
                try BackupFile.load(url, maxBytes: JournalV2Backup.maxBytes)
            }
            #expect(throws: BackupFileError.tooLarge) {
                try BackupFile.load(url)
            }
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
