import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain
import WorktimeStore

struct RetrospectiveStartTests {
    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("worktime.sqlite"))
    }

    private func sample(_ instant: Int64) throws -> ClockSample {
        try ClockSample(wall: instant, uptime: Double(instant))
    }

    @Test func `confirmed past start counts asserted work and preview is read only`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(900))
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            let profile = try WorkdayProfile()
            let proposal = try controller.previewRetrospectiveStart(at: 0, profile: profile, sample: sample(900))
            #expect(proposal.preview.snapshot.bounds.lower == 900)
            #expect(try store.load() == before)
            let result = try controller.commitRetrospectiveStart(proposal, sample: sample(905))
            #expect(result?.snapshot.bounds.lower == 905)
            #expect(result?.snapshot.bounds.upper == 905)
            let saved = try store.load()
            #expect(saved.version.revision == 1)
            let marker = try store.loadObservationCheckpoint(expected: saved.version)
            #expect(marker?.observedAt == 905)
            let repo = try CatalogRepository(url: url)
            let reopened = try repo.load(now: 905)
            #expect(reopened.catalog.days.first?.intervals.first?.start == 0)
        }
    }

    @Test func `future and overlapping starts leave store unchanged`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let profile = try WorkdayProfile()
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(100))
            _ = try controller.perform(.clockOut(confirmBreak: false), sample: sample(110))
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            for instant in [Int64(105), 121] {
                #expect(throws: RetrospectiveStartError.invalidStart) {
                    try controller.previewRetrospectiveStart(at: instant, profile: profile, sample: sample(120))
                }
            }
            #expect(try store.load() == before)
        }
    }

    @Test func `another command invalidates confirmation`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let profile = try WorkdayProfile()
            let proposal = try controller.previewRetrospectiveStart(at: 90, profile: profile, sample: sample(100))
            _ = try controller.perform(.clockIn(id: UUID(), profile: profile), sample: sample(101))
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            #expect(throws: RetrospectiveStartError.staleProposal) {
                try controller.commitRetrospectiveStart(proposal, sample: sample(102))
            }
            #expect(try store.load() == before)
        }
    }

    @Test func `unobserved gap before confirmation requires a new preview`() throws {
        try withDatabase { url in
            var controller = try WorktimeController(url: url, createIfMissing: true, sample: sample(100))
            let profile = try WorkdayProfile()
            let proposal = try controller.previewRetrospectiveStart(at: 90, profile: profile, sample: sample(100))
            let store = try SnapshotStore(url: url)
            let before = try store.load()
            #expect(throws: RetrospectiveStartError.staleProposal) {
                try controller.commitRetrospectiveStart(proposal, sample: sample(120))
            }
            #expect(try store.load() == before)
        }
    }
}
