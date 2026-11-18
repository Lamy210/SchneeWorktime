import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct WorktimeHistoryTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worktime.sqlite")
        try body(url, CatalogRepository(url: url, createIfMissing: true))
    }

    @Test func `ended history retains uncertainty and excludes current work`() throws {
        try withRepository { url, repo in
            let first = UUID()
            let profile = try WorkdayProfile(target: 100, expectedRest: 20)
            let initial = try repo.load(now: 100)
            let started = try repo.apply(.clockIn(id: first, profile: profile), at: 100, now: 100,
                                         expected: initial.version)
            let gap = ObservationGap(start: 120, end: 150)
            let observed = try repo.recordObservation(dayID: first, gap: gap, now: 160, expected: started.version)
            let review = try observed.previewReview(
                dayID: first, selection: .init(start: 120, end: 130), classification: .rest, now: 160
            )
            let corrected = try repo.commitReview(review, now: 160)
            let ended = try repo.apply(.clockOut(confirmBreak: false), at: 200, now: 200, expected: corrected.version)
            let active = try repo.apply(.clockIn(id: UUID(), profile: profile), at: 210, now: 210,
                                        expected: ended.version)
            let before = try SnapshotStore(url: url).load()
            let history = try WorktimeHistory(session: active, now: 210)
            let row = try #require(history.rows.first)
            #expect(history.rows.count == 1)
            #expect(row.id == first)
            #expect(row.worked == 70 ... 90)
            #expect(row.rest == 10)
            #expect(row.remaining == 10 ... 30)
            #expect(row.surplus == 0 ... 0)
            #expect(row.corrections == 1)
            #expect(row.endedAt == 200)
            #expect(try SnapshotStore(url: url).load() == before)
        }
    }

    @Test func `recent history is bounded and newest first`() throws {
        try withRepository { url, repo in
            var session = try repo.load(now: 100)
            let profile = try WorkdayProfile()
            var ids: [UUID] = []
            for index in 0 ..< 31 {
                let at = Int64(100 + index * 10)
                let id = UUID()
                ids.append(id)
                session = try repo.apply(.clockIn(id: id, profile: profile), at: at, now: at, expected: session.version)
                session = try repo.apply(.clockOut(confirmBreak: false), at: at + 1, now: at + 1,
                                         expected: session.version)
            }
            let history = try WorktimeHistory(session: session, now: 500)
            #expect(history.totalEndedDays == 31)
            #expect(history.rows.map(\.id) == Array(ids.suffix(30).reversed()))
            #expect(history.previousOffset == nil)
            #expect(history.nextOffset == 30)
            let controller = try WorktimeController(url: url, sample: ClockSample(wall: 500, uptime: 500))
            let older = try controller.recentHistory(now: 500, offset: 30, previous: history)
            #expect(older.rows.map(\.id) == [ids[0]])
            #expect(older.previousOffset == 0)
            #expect(older.nextOffset == nil)
            let returned = try controller.recentHistory(now: 500, offset: 0, previous: older)
            #expect(returned == history)
            for offset in [-1, 1, 31, 60, Int.max] {
                #expect(throws: WorktimeHistoryError.invalidOffset) {
                    try controller.recentHistory(now: 500, offset: offset, previous: history)
                }
            }
            #expect(throws: WorktimeHistoryError.stalePage) {
                try controller.recentHistory(now: 500, offset: 30)
            }
        }
    }

    @Test func `page navigation rejects a history from an earlier revision`() throws {
        try withRepository { url, _ in
            var controller = try WorktimeController(url: url, sample: ClockSample(wall: 100, uptime: 100))
            let history = try controller.recentHistory(now: 100)
            _ = try controller.perform(
                .clockIn(id: UUID(), profile: WorkdayProfile()), sample: ClockSample(wall: 101, uptime: 101)
            )
            #expect(throws: WorktimeHistoryError.stalePage) {
                try controller.recentHistory(now: 102, offset: 0, previous: history)
            }
            #expect(try controller.recentHistory(now: 102).version != history.version)
        }
    }

    @Test func `empty history is valid and stale controller cannot read history`() throws {
        try withRepository { url, repo in
            let sample = try ClockSample(wall: 100, uptime: 100)
            let controller = try WorktimeController(url: url, sample: sample)
            let history = try controller.recentHistory(now: 100)
            #expect(history.rows.isEmpty)
            let initial = try repo.load(now: 100)
            let command = try WorkdayCommand.clockIn(id: UUID(), profile: WorkdayProfile())
            _ = try repo.apply(command, at: 101, now: 101, expected: initial.version)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try controller.recentHistory(now: 101)
            }
        }
    }
}
