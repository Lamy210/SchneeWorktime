import Foundation
import Testing
import WorktimeApplication
import WorktimeStore

struct DesktopStorageLaunchGuardTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `release never creates a legacy store for a fresh installation`() throws {
        try fixture { url in
            #expect(try DesktopStorageLaunchGuard.decide(
                url: url, createIfMissing: true, allowLegacyDevelopment: false
            ) == .newInstallRequiresSchemaTwoUI)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(try DesktopStorageLaunchGuard.decide(
                url: url, createIfMissing: false, allowLegacyDevelopment: false
            ) == .missingDatabase)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func `only explicit developer mode can continue schema one support`() throws {
        try fixture { url in
            _ = try SnapshotStore(url: url, createIfMissing: true)
            let bytes = try Data(contentsOf: url)
            #expect(try DesktopStorageLaunchGuard.decide(
                url: url, createIfMissing: false, allowLegacyDevelopment: false
            ) == .legacyRequiresPreservation)
            #expect(try DesktopStorageLaunchGuard.decide(
                url: url, createIfMissing: false, allowLegacyDevelopment: true
            ) == .legacyDevelopmentOnly)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func `existing schema two is not passed into the old controller even in development`() throws {
        try fixture { url in
            _ = try JournalV2Repository(url: url, createIfMissing: true)
            let bytes = try Data(contentsOf: url)
            for development in [false, true] {
                #expect(try DesktopStorageLaunchGuard.decide(
                    url: url, createIfMissing: false, allowLegacyDevelopment: development
                ) == .schemaTwoAwaitingUI)
                #expect(try Data(contentsOf: url) == bytes)
            }
        }
    }

    @Test func `unknown schema fails closed even under development override`() throws {
        try fixture { url in
            try Data("corrupt".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try DesktopStorageLaunchGuard.decide(
                    url: url, createIfMissing: true, allowLegacyDevelopment: true
                )
            }
            #expect(try Data(contentsOf: url) == Data("corrupt".utf8))
        }
    }
}
