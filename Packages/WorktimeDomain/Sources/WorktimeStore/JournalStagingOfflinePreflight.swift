import Foundation

extension JournalStagingDatabase {
    /// Read-only offline comparison between an existing schema-1 file and a staged schema-2 candidate.
    /// The caller must hold the source session lock. This never authorizes live database adoption.
    static func preflightPreservedSource(
        at sourceURL: URL, candidateURL: URL, now: Int64
    ) throws -> JournalStagingInspection {
        let before = try SnapshotStore.readForPreservation(at: sourceURL)
        let inspected = try inspect(candidateURL, now: now)
        guard inspected.source == before else { throw JournalMigrationError.verificationFailed }
        // Detect an intervening source update while verifying the candidate.
        // A future adoption must still validate the source under an atomic CAS fence.
        let after = try SnapshotStore.readForPreservation(at: sourceURL)
        guard after == before else { throw JournalMigrationError.verificationFailed }
        return inspected
    }
}
