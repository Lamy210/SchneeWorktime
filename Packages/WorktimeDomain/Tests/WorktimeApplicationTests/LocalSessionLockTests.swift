import Foundation
import Testing
@testable import WorktimeApplication

struct LocalSessionLockTests {
    private func privateDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func `exclusive ownership and reopening after release`() throws {
        let url = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let lock = try LocalSessionLock(directory: url)
            _ = withExtendedLifetime(lock) {
                #expect(throws: LocalSessionLockError.alreadyLocked) {
                    try LocalSessionLock(directory: url)
                }
            }
        }
        let reopened = try LocalSessionLock(directory: url)
        withExtendedLifetime(reopened) {}
    }

    @Test func `public directory is rejected`() throws {
        let url = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        #expect(throws: LocalSessionLockError.unsafeDirectory) {
            try LocalSessionLock(directory: url)
        }
    }

    @Test func `directory symlink is rejected`() throws {
        let url = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let link = url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: LocalSessionLockError.unsafeDirectory) {
            try LocalSessionLock(directory: link)
        }
    }

    @Test func `lock symlink does not modify its target`() throws {
        let url = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let target = url.appendingPathComponent("target")
        let original = Data("preserve".utf8)
        try original.write(to: target)
        let link = url.appendingPathComponent("session.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: LocalSessionLockError.self) {
            try LocalSessionLock(directory: url)
        }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func `existing insecure lock is rejected without removal`() throws {
        let url = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let path = url.appendingPathComponent("session.lock")
        try Data().write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        #expect(throws: LocalSessionLockError.unsafeLockFile) {
            try LocalSessionLock(directory: url)
        }
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
}
