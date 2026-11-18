import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct SummaryControllerTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("worktime.sqlite"))
    }

    @Test func `period navigation is read only and invalidated by later commits`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(110))
            let period = try WorktimeSummaryPeriod(containing: 110, unit: .day, timeZoneID: "UTC")
            let repository = try CatalogRepository(url: url)
            let before = try repository.load(now: 111)
            let summary = try controller.summary(period: period, sample: sample(111))
            let earlier = try period.adjacent(previous: true)
            let old = try controller.summary(period: earlier, sample: sample(111), previous: summary)
            #expect(summary.worked == 10 ... 10)
            #expect(old.endedDays == 0)
            #expect(controller.isCurrent(summary))
            #expect(old.version == before.version)
            #expect(try repository.load(now: 111).version == before.version)
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(112))
            #expect(!controller.isCurrent(summary))
            #expect(throws: WorktimeSummaryError.staleSummary) {
                try controller.summary(period: earlier, sample: sample(113), previous: summary)
            }
        }
    }
}
