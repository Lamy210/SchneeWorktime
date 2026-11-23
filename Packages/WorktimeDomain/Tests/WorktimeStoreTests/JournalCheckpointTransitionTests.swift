import Foundation
import Testing
import WorktimeDomain
@testable import WorktimeStore

struct JournalCheckpointTransitionTests {
    private func withCandidate(
        _ body: (URL, URL, JournalStagingCandidate, CatalogRepository, UUID) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let repo = try CatalogRepository(url: sourceURL, createIfMissing: true)
        let initial = try repo.load(now: 90)
        let id = UUID()
        let started = try repo.apply(
            .clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100,
            expected: initial.version
        )
        try repo.saveObservationCheckpoint(dayID: id, observedAt: 110, expected: started.version)
        let candidate = try JournalStagingDatabase.createFromPreservedSource(
            at: sourceURL, in: root, now: 120
        )
        try body(root, sourceURL, candidate, repo, id)
    }

    @Test func `active candidate requires a fresh next generation observation`() throws {
        try withCandidate { _, sourceURL, candidate, _, id in
            let sourceBefore = try Data(contentsOf: sourceURL)
            let candidateBefore = try Data(contentsOf: candidate.url)
            let plan = try JournalStagingDatabase.inspectCheckpointTransition(
                sourceURL: sourceURL, candidate: candidate, now: 130
            )
            #expect(plan.activeDayID == id)
            #expect(plan.candidateVersion == candidate.draft.candidateVersion)
            #expect(plan.observedAfter == 110)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try plan.validateReplacement(nil, now: 130)
            }
            let old = ObservationCheckpoint(
                version: candidate.draft.source.version, dayID: id, observedAt: 120
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try plan.validateReplacement(old, now: 130)
            }
            let stale = ObservationCheckpoint(
                version: plan.candidateVersion, dayID: id, observedAt: 110
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try plan.validateReplacement(stale, now: 130)
            }
            let wrongDay = ObservationCheckpoint(
                version: plan.candidateVersion, dayID: UUID(), observedAt: 120
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try plan.validateReplacement(wrongDay, now: 130)
            }
            let future = ObservationCheckpoint(
                version: plan.candidateVersion, dayID: id, observedAt: 140
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try plan.validateReplacement(future, now: 130)
            }
            let fresh = ObservationCheckpoint(
                version: plan.candidateVersion, dayID: id, observedAt: 120
            )
            try plan.validateReplacement(fresh, now: 130)
            #expect(try Data(contentsOf: sourceURL) == sourceBefore)
            #expect(try Data(contentsOf: candidate.url) == candidateBefore)
        }
    }

    @Test func `new candidate event raises the fresh observation lower bound`() throws {
        try withCandidate { _, sourceURL, candidate, _, id in
            let event = JournalEvent(
                action: .futureRest(dayID: id, remainingSeconds: 60), now: 130
            )
            let committed = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                event, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 140
            )
            let plan = try JournalStagingDatabase.inspectCheckpointTransition(
                sourceURL: sourceURL, candidate: candidate, now: 140
            )
            #expect(plan.candidateVersion == committed.version)
            #expect(plan.observedAfter == 130)
            let stale = ObservationCheckpoint(
                version: committed.version, dayID: id, observedAt: 130
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try plan.validateReplacement(stale, now: 140)
            }
            try plan.validateReplacement(
                ObservationCheckpoint(version: committed.version, dayID: id, observedAt: 131),
                now: 140
            )
        }
    }

    @Test func `ended candidate requires no active observation checkpoint`() throws {
        try withCandidate { _, sourceURL, candidate, _, id in
            let exit = JournalEvent(action: .command(.clockOut(confirmBreak: false), at: 130), now: 130)
            let committed = try JournalStagingDatabase.appendOfflineFromPreservedSource(
                exit, sourceURL: sourceURL, candidate: candidate,
                expected: candidate.draft.candidateVersion, now: 140
            )
            let plan = try JournalStagingDatabase.inspectCheckpointTransition(
                sourceURL: sourceURL, candidate: candidate, now: 140
            )
            #expect(plan.candidateVersion == committed.version)
            #expect(plan.activeDayID == nil)
            try plan.validateReplacement(nil, now: 140)
            #expect(throws: JournalMigrationError.verificationFailed) {
                try plan.validateReplacement(
                    ObservationCheckpoint(version: committed.version, dayID: id, observedAt: 135),
                    now: 140
                )
            }
        }
    }

    @Test func `changed source checkpoint invalidates the transition plan`() throws {
        try withCandidate { _, sourceURL, candidate, repo, id in
            try repo.saveObservationCheckpoint(
                dayID: id, observedAt: 115, expected: candidate.draft.source.version
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.inspectCheckpointTransition(
                    sourceURL: sourceURL, candidate: candidate, now: 140
                )
            }
        }
    }

    @Test func `unbound candidate has no checkpoint transition authority`() throws {
        try withCandidate { root, sourceURL, candidate, _, _ in
            let unbound = try JournalStagingDatabase.create(
                source: candidate.draft.source, in: root, now: 140
            )
            #expect(throws: JournalMigrationError.verificationFailed) {
                try JournalStagingDatabase.inspectCheckpointTransition(
                    sourceURL: sourceURL, candidate: unbound, now: 140
                )
            }
        }
    }
}
