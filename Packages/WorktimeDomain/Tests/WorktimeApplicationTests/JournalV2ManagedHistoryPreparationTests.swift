import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct JournalV2ManagedHistoryPreparationTests {
    private func sample(_ at: Int64) throws -> ClockSample {
        try ClockSample(wall: at, uptime: Double(at))
    }

    private func fixture(_ body: (URL, JournalV2WorktimeController) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        let current = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        try body(url, current)
    }

    @Test func `explicit preparation initializes and registers a backup without editing the journal`() throws {
        try fixture { url, current in
            let original = try JournalV2Repository.inspectReadOnly(url: url, now: 100)
            let absent = try current.previewManagedHistory(sample: sample(101))
            #expect(absent.scope.state == .notInitialized)
            let initialized = try current.prepareManagedHistory(.initialize, matching: absent, sample: sample(102))
            #expect(initialized.scope.state == .inventoried)
            #expect(initialized.scope.verifiedFiles == 0)
            let saved = try current.prepareManagedHistory(.backup, matching: initialized, sample: sample(103))
            #expect(saved.scope.registeredBackups == 1)
            #expect(saved.scope.verifiedFiles == 1)
            #expect(throws: JournalV2ManagedHistoryPreparationError.stalePreview) {
                try current.prepareManagedHistory(.backup, matching: initialized, sample: sample(104))
            }
            let final = try JournalV2Repository.inspectReadOnly(url: url, now: 105)
            #expect(JournalV2Repository.sameCommittedState(original, final))
        }
    }

    @Test func `new session or partial setup invalidates preparation without adopting files`() throws {
        try fixture { url, current in
            let absent = try current.previewManagedHistory(sample: sample(101))
            let reopened = try JournalV2WorktimeController(url: url, sample: sample(102))
            #expect(throws: JournalV2ManagedHistoryPreparationError.stalePreview) {
                try reopened.prepareManagedHistory(.initialize, matching: absent, sample: sample(103))
            }
            let root = url.deletingLastPathComponent()
            let directory = root.appendingPathComponent("managed-history-v1", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            let unknown = directory.appendingPathComponent("unknown.json")
            let bytes = Data("not owned".utf8)
            try bytes.write(to: unknown)
            #expect(throws: JournalV2ManagedHistoryPreparationError.stalePreview) {
                try current.prepareManagedHistory(.initialize, matching: absent, sample: sample(104))
            }
            let partial = try current.previewManagedHistory(sample: sample(105))
            #expect(partial.scope.state == .incompleteSetup)
            #expect(throws: JournalV2ManagedHistoryPreparationError.unavailable) {
                try current.prepareManagedHistory(.initialize, matching: partial, sample: sample(106))
            }
            #expect(try Data(contentsOf: unknown) == bytes)
        }
    }
}
