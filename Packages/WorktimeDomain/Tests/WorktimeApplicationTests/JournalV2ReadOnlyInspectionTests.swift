import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2ReadOnlyInspectionTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `read only inspection refuses missing DB without creating a sqlite file`() throws {
        try fixture { url in
            #expect(throws: DatabaseFileError.self) {
                try JournalV2ReadOnlyInspection(url: url, now: 100)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func `working day inspection does not advance checkpoint or fabricate elapsed work`() throws {
        try fixture { url in
            let repo = try JournalV2Repository(url: url, createIfMissing: true)
            let initial = try repo.load(now: 100)
            let id = UUID()
            let working = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
                matching: initial, observedAt: 100
            )
            let raw = try Data(contentsOf: url)
            let inspection = try JournalV2ReadOnlyInspection(url: url, now: 140)
            #expect(inspection.version == working.version)
            #expect(inspection.workdays == 1)
            #expect(inspection.endedDays == 0)
            #expect(inspection.corrections == 0)
            #expect(inspection.activeDay?.id == id)
            #expect(inspection.lastObservedAt == 100)
            #expect(inspection.history.rows.isEmpty)
            let unchanged = try repo.load(now: 140)
            #expect(unchanged.checkpoint == working.checkpoint)
            #expect(unchanged.catalog == working.catalog)
            #expect(try Data(contentsOf: url) == raw)
        }
    }

    @Test func `all historical pages use the same version and never write back`() throws {
        try fixture { url in
            let repo = try JournalV2Repository(url: url, createIfMissing: true)
            var current = try repo.load(now: 100)
            var ids: [UUID] = []
            for index in 0 ..< 31 {
                let id = UUID()
                ids.append(id)
                let start = Int64(100 + index * 10)
                current = try repo.apply(
                    .clockIn(id: id, profile: WorkdayProfile()), at: start, now: start,
                    matching: current, observedAt: start
                )
                current = try repo.apply(
                    .clockOut(confirmBreak: false), at: start + 5, now: start + 5,
                    matching: current
                )
            }
            let raw = try Data(contentsOf: url)
            let first = try JournalV2ReadOnlyInspection(url: url, now: 500)
            #expect(first.workdays == 31)
            #expect(first.endedDays == 31)
            #expect(first.history.rows.map(\.id) == Array(ids.suffix(30).reversed()))
            #expect(first.history.nextOffset == 30)
            let older = try JournalV2ReadOnlyInspection(
                url: url, now: 500, offset: 30, previous: first
            )
            #expect(older.history.rows.map(\.id) == [ids[0]])
            #expect(older.history.nextOffset == nil)
            #expect(older.version == first.version)
            #expect(try Data(contentsOf: url) == raw)
            #expect(throws: WorktimeHistoryError.stalePage) {
                try JournalV2ReadOnlyInspection(url: url, now: 500, offset: 30)
            }
        }
    }

    @Test func `checkpoint only competitor invalidates history navigation at same revision`() throws {
        try fixture { url in
            let repo = try JournalV2Repository(url: url, createIfMissing: true)
            let id = UUID()
            let working = try repo.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
                matching: repo.load(now: 100), observedAt: 100
            )
            let page = try JournalV2ReadOnlyInspection(url: url, now: 101)
            let changed = try repo.saveObservationCheckpoint(
                dayID: id, observedAt: 105, now: 105, matching: working
            )
            #expect(changed.version == page.version)
            #expect(throws: WorktimeHistoryError.stalePage) {
                try JournalV2ReadOnlyInspection(url: url, now: 106, previous: page)
            }
        }
    }

    @Test func `legacy database and unknown header cannot be viewed as schema two`() throws {
        try fixture { url in
            _ = try SnapshotStore(url: url, createIfMissing: true)
            let before = try Data(contentsOf: url)
            #expect(throws: SnapshotStoreError.unsupportedSchema) {
                try JournalV2ReadOnlyInspection(url: url, now: 100)
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func `symlink and hot journal do not become readable through history inspection`() throws {
        try fixture { url in
            _ = try JournalV2Repository(url: url, createIfMissing: true)
            let link = url.deletingLastPathComponent().appendingPathComponent("alias.sqlite")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            #expect(throws: DatabaseFileError.unsafeFile) {
                try JournalV2ReadOnlyInspection(url: link, now: 100)
            }
            let sidecar = URL(fileURLWithPath: url.path + "-journal")
            try Data([7, 8]).write(to: sidecar)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: sidecar.path
            )
            #expect(throws: DatabaseFileError.unsafeFile) {
                try JournalV2ReadOnlyInspection(url: url, now: 100)
            }
            #expect(try Data(contentsOf: sidecar) == Data([7, 8]))
        }
    }
}
