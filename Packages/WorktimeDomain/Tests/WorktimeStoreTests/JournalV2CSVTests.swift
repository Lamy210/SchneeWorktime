import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalV2CSVTests {
    private func fixture(
        _ body: (URL, JournalV2Repository, JournalV2Session) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try JournalV2Repository(
            url: root.appendingPathComponent("worktime.sqlite"), createIfMissing: true
        )
        try body(root, repository, try repository.load(now: 100))
    }

    private func rows(_ data: Data) -> [[String]] {
        (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: ",") }
    }

    @Test func `empty schema two generation retains epoch and fourteen columns`() throws {
        try fixture { _, repository, initial in
            let output = try rows(repository.makeCSV(now: 100, matching: initial))
            #expect(output.count == 2)
            #expect(output.allSatisfy { $0.count == 14 })
            #expect(output[1][0] == "snapshot")
            #expect(output[1][12] == initial.version.epoch.uuidString)
            #expect(output[1][13] == "0")
        }
    }

    @Test func `schema two audit CSV is consistent and never mutates live journal`() throws {
        try fixture { root, repository, initial in
            let id = UUID()
            let started = try repository.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
                matching: initial, observedAt: 100
            )
            let observed = try repository.recordObservation(
                dayID: id, gap: .init(start: 120, end: 150), now: 160, matching: started
            )
            let proposal = try repository.previewReview(
                dayID: id, selection: .init(start: 120, end: 130),
                classification: .rest, now: 160, matching: observed
            )
            let reviewed = try repository.commitReview(proposal, now: 161)
            let csv = try repository.makeCSV(now: 170, matching: reviewed)
            let output = rows(csv)
            #expect(output.allSatisfy { $0.count == 14 })
            #expect(output[1][12] == reviewed.version.epoch.uuidString)
            #expect(output[1][13] == String(reviewed.version.revision))
            #expect(output.contains { $0[0] == "correction" })
            #expect(output.contains { $0[0] == "unverified" })
            #expect(csv == (try CatalogCSV.encode(
                catalog: reviewed.catalog, version: reviewed.version
            )))
            let target = root.appendingPathComponent("schema2.csv")
            try repository.writeCSV(to: target, now: 170, matching: reviewed)
            #expect(try BackupFile.load(target) == csv)
            #expect(try repository.load(now: 170).version == reviewed.version)
            #expect(throws: BackupFileError.self) {
                try repository.writeCSV(to: target, now: 170, matching: reviewed)
            }
            #expect(try BackupFile.load(target) == csv)
        }
    }

    @Test func `checkpoint-only update fences stale CSV even at same revision`() throws {
        try fixture { root, repository, initial in
            let id = UUID()
            let started = try repository.apply(
                .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
                matching: initial, observedAt: 100
            )
            let newer = try repository.saveObservationCheckpoint(
                dayID: id, observedAt: 110, now: 110, matching: started
            )
            #expect(started.version == newer.version)
            let target = root.appendingPathComponent("stale.csv")
            #expect(throws: JournalMigrationError.verificationFailed) {
                try repository.writeCSV(to: target, now: 110, matching: started)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try repository.makeCSV(now: 110, matching: newer).count > 0)
        }
    }

    @Test func `reset epoch fences CSV from deleted generation`() throws {
        try fixture { root, repository, initial in
            let started = try repository.apply(
                .clockIn(id: UUID(), profile: WorkdayProfile()), at: 100, now: 100,
                matching: initial
            )
            let preview = try repository.previewReset(now: 110, matching: started)
            let reset = try repository.commitReset(preview, now: 111)
            #expect(throws: SnapshotStoreError.staleVersion) {
                try repository.writeCSV(
                    to: root.appendingPathComponent("old.csv"), now: 112, matching: started
                )
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old.csv").path))
            #expect(rows(try repository.makeCSV(now: 112, matching: reset)).count == 2)
        }
    }
}
