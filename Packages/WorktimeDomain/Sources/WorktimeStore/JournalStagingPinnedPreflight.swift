import Foundation

extension JournalStagingDatabase {
    /// Read-only preflight for an in-memory staging capability. The source must remain locked.
    /// Verifies exact original row bytes as well as candidate/source file identities.
    static func preflightPinnedCandidate(
        sourceURL: URL, candidate: JournalStagingCandidate, now: Int64
    ) throws -> JournalStagingInspection {
        guard let preserved = candidate.capturedSource else {
            throw JournalMigrationError.verificationFailed
        }
        try preserved.verifyUnchanged(at: sourceURL)
        guard try DatabaseFileGuard.preservationIdentity(candidate.url) == candidate.fileIdentity else {
            throw DatabaseFileError.unsafeFile
        }
        let inspected = try inspect(candidate.url, now: now)
        guard inspected.source == preserved.snapshot,
              candidate.draft.source == preserved.snapshot,
              inspected.version.epoch == candidate.draft.candidateVersion.epoch,
              inspected.checkpointAnchor != .unbound,
              inspected.checkpointAnchor == .captured(preserved.checkpoint),
              Array(inspected.rows.prefix(candidate.draft.rows.count)) == candidate.draft.rows
        else { throw JournalMigrationError.verificationFailed }
        guard try DatabaseFileGuard.preservationIdentity(candidate.url) == candidate.fileIdentity else {
            throw DatabaseFileError.unsafeFile
        }
        try preserved.verifyUnchanged(at: sourceURL)
        return inspected
    }
}
