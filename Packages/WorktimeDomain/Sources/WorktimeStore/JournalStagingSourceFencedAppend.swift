import Foundation
import WorktimeDomain

extension JournalStagingDatabase {
    /// Offline append bound to a separately preserved schema-1 source and its checkpoint.
    /// Caller MUST hold the original directory/session lock until this operation returns.
    /// This is not an atomic live migration or an authorization to adopt the candidate.
    static func appendOfflineFromPreservedSource(
        _ event: JournalEvent, sourceURL: URL, candidate: JournalStagingCandidate,
        expected: StoreVersion, now: Int64
    ) throws -> JournalStagingInspection {
        guard let preserved = candidate.capturedSource else {
            throw JournalMigrationError.verificationFailed
        }
        // The original inode must match the one captured when staging was created.
        // A byte-identical replacement between creation and append is unsafe.
        try preserved.verifyUnchanged(at: sourceURL)
        guard try DatabaseFileGuard.preservationIdentity(candidate.url) == candidate.fileIdentity else {
            throw DatabaseFileError.unsafeFile
        }
        let inspected = try inspect(candidate.url, now: now)
        guard inspected.source == preserved.snapshot,
              candidate.draft.source == preserved.snapshot,
              inspected.version.epoch == candidate.draft.candidateVersion.epoch,
              inspected.checkpointAnchor != .unbound,
              inspected.checkpointAnchor == .captured(preserved.checkpoint)
        else { throw JournalMigrationError.verificationFailed }
        guard inspected.version == expected else { throw SnapshotStoreError.staleVersion }
        try preserved.verifyUnchanged(at: sourceURL)
        let committed = try appendOffline(
            event, to: candidate.url, anchoredTo: preserved.snapshot, expected: expected, now: now
        )
        // Writes to the original must remain locked out. A post-COMMIT error is ambiguous:
        // the event may already be durable, so an automatic retry is unsafe.
        do {
            guard try DatabaseFileGuard.preservationIdentity(candidate.url) == candidate.fileIdentity else {
                throw DatabaseFileError.unsafeFile
            }
            try preserved.verifyUnchanged(at: sourceURL)
        } catch {
            throw JournalStagingAppendError.committedButUnverified(committed.version)
        }
        return committed
    }
}
