import Foundation

extension JournalStagingDatabase {
    /// Read-only offline comparison between an existing schema-1 file and a staged schema-2 candidate.
    /// The caller must hold the source session lock. This never authorizes live database adoption.
    static func preflightPreservedSource(
        at sourceURL: URL, candidateURL: URL, now: Int64
    ) throws -> JournalStagingInspection {
        let source = try JournalPreservedSourceCapture.read(at: sourceURL)
        let inspected = try inspect(candidateURL, now: now)
        guard inspected.source == source.snapshot else { throw JournalMigrationError.verificationFailed }
        let bound = inspected.checkpointAnchor != .unbound
        let changed = inspected.checkpointAnchor != .captured(source.checkpoint)
        if bound, changed {
            throw JournalMigrationError.verificationFailed
        }
        // Detect replacement by an identical copy, as well as updates to the stored snapshot.
        // A future adoption must still validate the source under an atomic CAS fence.
        try source.verifyUnchanged(at: sourceURL)
        return inspected
    }
}
