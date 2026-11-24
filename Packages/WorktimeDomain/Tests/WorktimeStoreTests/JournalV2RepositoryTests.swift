import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2RepositoryTests {
    private func fixture(_ body: (URL, JournalV2Repository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(url, JournalV2Repository(url: url, createIfMissing: true))
    }

    private func start(_ repository: JournalV2Repository, id: UUID) throws -> JournalV2Session {
        try repository.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
            matching: repository.load(now: 100), observedAt: 100
        )
    }

    @Test func `repository can clock in and out with a durable generation`() throws {
        try fixture { url, repository in
            let started = try start(repository, id: UUID())
            #expect(started.version.revision == 1)
            #expect(started.checkpoint?.version == started.version)
            let finished = try repository.apply(
                .clockOut(confirmBreak: false), at: 150, now: 150, matching: started
            )
            #expect(finished.version.revision == 2)
            #expect(finished.checkpoint == nil)
            #expect(finished.catalog.activeID == nil)
            let reopened = try JournalV2Repository(url: url).load(now: 160)
            #expect(reopened.version == finished.version)
            #expect(reopened.catalog == finished.catalog)
            #expect(reopened.checkpoint == nil)
        }
    }

    @Test func `checkpoint only update fences a same revision stale session`() throws {
        try fixture { _, repository in
            let id = UUID()
            let started = try start(repository, id: id)
            let updated = try repository.saveObservationCheckpoint(
                dayID: id, observedAt: 110, now: 110, matching: started
            )
            #expect(updated.version == started.version)
            #expect(updated.checkpoint?.observedAt == 110)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repository.revalidate(started, now: 110)
            }
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repository.apply(
                    .clockOut(confirmBreak: false), at: 120, now: 120, matching: started
                )
            }
            let completed = try repository.apply(
                .clockOut(confirmBreak: false), at: 120, now: 120, matching: updated
            )
            #expect(completed.catalog.activeID == nil)
        }
    }

    @Test func `invalid command leaves checkpoint and journal intact`() throws {
        try fixture { url, repository in
            let started = try start(repository, id: UUID())
            #expect(throws: WorkdayError.self) {
                try repository.apply(.endBreak, at: 110, now: 110, matching: started)
            }
            let disk = try JournalV2Repository(url: url).load(now: 120)
            #expect(disk.version == started.version)
            #expect(disk.checkpoint == started.checkpoint)
            #expect(disk.catalog == started.catalog)
        }
    }

    @Test func `stale deletion preview cannot erase a newer session`() throws {
        try fixture { url, repository in
            let id = UUID()
            let started = try start(repository, id: id)
            let preview = try repository.previewReset(now: 105, matching: started)
            #expect(preview.workdays == 1)
            #expect(preview.hasActiveWorkday)
            let updated = try repository.saveObservationCheckpoint(
                dayID: id, observedAt: 110, now: 110, matching: started
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repository.commitReset(preview, now: 120)
            }
            #expect(try JournalV2Repository(url: url).load(now: 120).checkpoint == updated.checkpoint)
        }
    }

    @Test func `confirmed logical deletion fences prior epoch`() throws {
        try fixture { url, repository in
            let started = try start(repository, id: UUID())
            let preview = try repository.previewReset(now: 110, matching: started)
            let cleared = try repository.commitReset(preview, now: 120)
            #expect(cleared.version.revision == 0)
            #expect(cleared.version.epoch != started.version.epoch)
            #expect(cleared.catalog.days.isEmpty)
            #expect(cleared.checkpoint == nil)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repository.revalidate(started, now: 130)
            }
            #expect(try JournalV2Repository(url: url).load(now: 130).version == cleared.version)
        }
    }

    @Test func `schema one file is refused without an automatic overwrite`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        _ = try CatalogRepository(url: url, createIfMissing: true)
        let before = try Data(contentsOf: url)
        #expect(throws: SnapshotStoreError.unsupportedSchema) {
            try JournalV2Repository(url: url, createIfMissing: true)
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
