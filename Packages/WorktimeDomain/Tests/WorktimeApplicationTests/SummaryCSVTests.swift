import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct SummaryCSVTests {
    private func sample(_ seconds: Int64) throws -> ClockSample {
        try ClockSample(wall: seconds, uptime: Double(seconds))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func rows(_ data: Data) -> [[String]] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }.map { $0.components(separatedBy: ",") }
    }

    @Test func `export preserves displayed bounds and source version without changing live record`() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("live.sqlite")
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(100))
            _ = try controller.refresh(sample: sample(110))
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(140))
            let period = try WorktimeSummaryPeriod(containing: 140, unit: .day, timeZoneID: "UTC")
            let summary = try controller.summary(period: period, sample: sample(141))
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            let output = directory.appendingPathComponent("summary.csv")
            try controller.writeSummaryCSV(summary, to: output, sample: sample(142))
            let decoded = try rows(Data(contentsOf: output))
            #expect(decoded.count == 3)
            #expect(decoded.allSatisfy { $0.count == 19 })
            #expect(decoded[1][0] == "summary")
            #expect(decoded[2][0] == "day")
            #expect(Array(decoded[1][6 ... 8]) == ["1", "10", "40"])
            #expect(Array(decoded[2][6 ... 8]) == ["1", "10", "40"])
            #expect(decoded[1][16] == summary.version.epoch.uuidString)
            #expect(decoded[1][17] == String(summary.version.revision))
            #expect(decoded[1][18] == "141")
            #expect(try store.load() == before)
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            #expect(throws: BackupFileError.self) {
                try controller.writeSummaryCSV(summary, to: output, sample: sample(143))
            }
            #expect(try rows(Data(contentsOf: output)) == decoded)
        }
    }

    @Test func `empty export contains metadata and stale summary creates no file`() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("live.sqlite")
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let period = try WorktimeSummaryPeriod(containing: 100, unit: .week, timeZoneID: "UTC")
            let summary = try controller.summary(period: period, sample: sample(100))
            let decoded = rows(WorktimeSummaryCSV.encode(summary))
            #expect(decoded.count == 2)
            #expect(decoded.allSatisfy { $0.count == 19 })
            #expect(decoded[1][6] == "0")
            _ = try controller.perform(.clockIn(id: UUID(), profile: WorkdayProfile()), sample: sample(101))
            let output = directory.appendingPathComponent("stale.csv")
            #expect(throws: WorktimeSummaryError.staleSummary) {
                try controller.writeSummaryCSV(summary, to: output, sample: sample(102))
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }
}
