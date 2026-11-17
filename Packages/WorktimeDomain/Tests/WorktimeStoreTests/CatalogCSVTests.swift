import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct CatalogCSVTests {
    private func withRepository(_ body: (URL, CatalogRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CatalogRepository(url: root.appendingPathComponent("worktime.sqlite"), createIfMissing: true)
        try body(root, repo)
    }

    private func rows(_ data: Data) -> [[String]] {
        (String(bytes: data, encoding: .utf8) ?? "").components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }.map { $0.components(separatedBy: ",") }
    }

    @Test func `empty catalog retains source version and exact column count`() throws {
        try withRepository { _, repo in
            let initial = try repo.load(now: 100)
            let output = try CatalogCSV.encode(initial)
            let decoded = rows(output)
            #expect(decoded.count == 2)
            #expect(decoded.allSatisfy { $0.count == 14 })
            #expect(decoded[1][0] == "snapshot")
            #expect(decoded[1][12] == initial.version.epoch.uuidString)
            #expect(decoded[1][13] == "0")
        }
    }

    @Test func `export preserves intervals uncertainty and correction provenance without inventing end`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let id = UUID()
            let profile = try WorkdayProfile()
            let started = try repo.apply(.clockIn(id: id, profile: profile), at: 100, now: 100,
                                         expected: initial.version)
            let observed = try repo.recordObservation(
                dayID: id, gap: .init(start: 120, end: 150), now: 160, expected: started.version
            )
            let review = try observed.previewReview(
                dayID: id, selection: .init(start: 120, end: 130), classification: .rest, now: 160
            )
            let saved = try repo.commitReview(review, now: 160)
            let before = try SnapshotStore(url: root.appendingPathComponent("worktime.sqlite")).load()
            let output = root.appendingPathComponent("history.csv")
            try repo.writeCSV(to: output, now: 170, expected: saved.version)
            let decoded = try rows(Data(contentsOf: output))
            #expect(decoded.count == 7)
            #expect(decoded.allSatisfy { $0.count == 14 })
            let records = Array(decoded.dropFirst(2))
            #expect(records.map { $0[0] } == ["interval", "interval", "interval", "unverified", "correction"])
            #expect(Array(records[1][4 ... 6]) == ["rest", "120", "130"])
            #expect(Array(records[2][4 ... 6]) == ["work", "130", ""])
            #expect(Array(records[3][5 ... 6]) == ["130", "150"])
            #expect(Array(records[4][4 ... 6]) == ["rest", "120", "130"])
            #expect(records[4][9] == String(saved.catalog.reviewAudit[0].revision))
            #expect(records[4][11] == "160")
            #expect(try SnapshotStore(url: root.appendingPathComponent("worktime.sqlite")).load() == before)
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            #expect(throws: BackupFileError.self) {
                try repo.writeCSV(to: output, now: 170, expected: saved.version)
            }
            #expect(try rows(Data(contentsOf: output)) == decoded)
        }
    }

    @Test func `stale source version refuses output`() throws {
        try withRepository { root, repo in
            let initial = try repo.load(now: 100)
            let command = try WorkdayCommand.clockIn(id: UUID(), profile: WorkdayProfile())
            _ = try repo.apply(command, at: 100, now: 100, expected: initial.version)
            let output = root.appendingPathComponent("history.csv")
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repo.writeCSV(to: output, now: 100, expected: initial.version)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }
}
