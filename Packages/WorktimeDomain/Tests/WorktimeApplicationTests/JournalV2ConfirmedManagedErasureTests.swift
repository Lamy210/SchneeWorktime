import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ConfirmedManagedErasureTests {
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
        var current = try JournalV2WorktimeController(url: url, createIfMissing: true, sample: sample(100))
        _ = try current.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(101))
        let absent = try current.previewManagedHistory(sample: sample(102))
        let initialized = try current.prepareManagedHistory(.initialize, matching: absent, sample: sample(103))
        _ = try current.prepareManagedHistory(.backup, matching: initialized, sample: sample(104))
        try body(url, current)
    }

    @Test func `consent and notification gate precede a complete managed erasure`() throws {
        try fixture { (url: URL, initial: JournalV2WorktimeController) throws in
            var current = initial
            let root = url.deletingLastPathComponent()
            let original = try JournalV2Repository.inspectReadOnly(url: url, now: 105)
            let registry = try ManagedHistoryRegistryFile.load(in: root)
            let entry = try #require(registry.entries.first)
            let directory = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
            let file = directory.appendingPathComponent(entry.name)
            let external = root.appendingPathComponent(entry.name)
            let bytes = try Data(contentsOf: file)
            try bytes.write(to: external)
            let confirmation = try current.previewConfirmedManagedErasure(
                matching: current.workActionContext, sample: sample(105)
            )
            #expect(confirmation.scope.verifiedFiles == 1)
            #expect(confirmation.scope.hasActiveWorkday)
            #expect(throws: JournalV2ConfirmedManagedErasureError.missingConsent) {
                try current.commitConfirmedManagedErasure(
                    confirmation, consent: "削除", notificationsSettled: true, sample: sample(106)
                )
            }
            #expect(throws: JournalV2ConfirmedManagedErasureError.notificationsNotSettled) {
                try current.commitConfirmedManagedErasure(
                    confirmation, consent: "全履歴削除", notificationsSettled: false, sample: sample(106)
                )
            }
            #expect(try !ManagedHistoryStartupFence.hasPending(in: root))
            let unchanged = try JournalV2Repository.inspectReadOnly(url: url, now: 106)
            #expect(JournalV2Repository.sameCommittedState(original, unchanged))
            try current.commitConfirmedManagedErasure(
                confirmation, consent: "全履歴削除", notificationsSettled: true, sample: sample(107)
            )
            #expect(current.version.epoch != original.version.epoch)
            #expect(current.version.revision == 0)
            #expect(current.checkpoint == nil)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try Data(contentsOf: external) == bytes)
            #expect(try !ManagedHistoryStartupFence.hasPending(in: root))
            let fresh = try current.previewManagedHistory(sample: sample(108))
            #expect(fresh.scope.workdays == 0)
            #expect(fresh.scope.registeredBackups == 0)
            #expect(throws: JournalV2ConfirmedManagedErasureError.staleConfirmation) {
                try current.commitConfirmedManagedErasure(
                    confirmation, consent: "全履歴削除", notificationsSettled: true, sample: sample(109)
                )
            }
        }
    }

    @Test func `new registered backup invalidates the immutable deletion plan`() throws {
        try fixture { (url: URL, initial: JournalV2WorktimeController) throws in
            var current = initial
            let root = url.deletingLastPathComponent()
            let confirmation = try current.previewConfirmedManagedErasure(
                matching: current.workActionContext, sample: sample(105)
            )
            let scope = try current.previewManagedHistory(sample: sample(106))
            _ = try current.prepareManagedHistory(.backup, matching: scope, sample: sample(107))
            let registry = try ManagedHistoryRegistryFile.load(in: root)
            #expect(registry.entries.count == 2)
            #expect(throws: ManagedHistoryPersistenceError.incompleteInventory) {
                try current.commitConfirmedManagedErasure(
                    confirmation, consent: "全履歴削除", notificationsSettled: true, sample: sample(108)
                )
            }
            #expect(try !ManagedHistoryStartupFence.hasPending(in: root))
            let unchanged = try JournalV2Repository.inspectReadOnly(url: url, now: 109)
            #expect(unchanged.version == current.version)
            #expect(unchanged.catalog.days.count == 1)
            #expect(try ManagedHistoryRegistryFile.load(in: root) == registry)
        }
    }

    @Test func `routine checkpoint refresh invalidates confirmation before publication`() throws {
        try fixture { (url: URL, initial: JournalV2WorktimeController) throws in
            var current = initial
            let root = url.deletingLastPathComponent()
            let confirmation = try current.previewConfirmedManagedErasure(
                matching: current.workActionContext, sample: sample(105)
            )
            _ = try current.refresh(sample: sample(106))
            #expect(throws: JournalV2ConfirmedManagedErasureError.staleConfirmation) {
                try current.commitConfirmedManagedErasure(
                    confirmation, consent: "全履歴削除", notificationsSettled: true, sample: sample(107)
                )
            }
            #expect(try !ManagedHistoryStartupFence.hasPending(in: root))
            let saved = try JournalV2Repository.inspectReadOnly(url: url, now: 108)
            #expect(saved.catalog.days.count == 1)
            #expect(saved.checkpoint == current.checkpoint)
        }
    }
}
