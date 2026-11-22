import Foundation
import WorktimeDomain

extension JournalStagingDatabase {
    /// Offline append bound to a separately preserved schema-1 source and its checkpoint.
    /// Caller MUST hold the original directory/session lock until this operation returns.
    /// This is not an atomic live migration or an authorization to adopt the candidate.
    static func appendOfflineFromPreservedSource(
        _ event: JournalEvent, sourceURL: URL, candidateURL: URL,
        expected: StoreVersion, now: Int64
    ) throws -> JournalStagingInspection {
        let preserved = try JournalPreservedSourceCapture.read(at: sourceURL)
        let candidate = try inspect(candidateURL, now: now)
        guard candidate.source == preserved.snapshot,
              candidate.checkpointAnchor != .unbound,
              candidate.checkpointAnchor == .captured(preserved.checkpoint)
        else { throw JournalMigrationError.verificationFailed }
        guard candidate.version == expected else { throw SnapshotStoreError.staleVersion }
        try preserved.verifyUnchanged(at: sourceURL)
        let committed = try appendOffline(
            event, to: candidateURL, anchoredTo: preserved.snapshot, expected: expected, now: now
        )
        // Writes to the original must remain locked out. A post-COMMIT error is ambiguous:
        // the event may already be durable, so an automatic retry is unsafe.
        do {
            try preserved.verifyUnchanged(at: sourceURL)
        } catch {
            throw JournalStagingAppendError.committedButUnverified(committed.version)
        }
        return committed
    }
}
