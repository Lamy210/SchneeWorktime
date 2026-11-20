import Foundation

extension JournalStagingDatabase {
    /// Build an offline schema-2 candidate from an existing schema-1 file without opening it for writes.
    ///
    /// Caller must hold the app's session lock and prevent concurrent writes to the source.
    /// This is not an adoption operation. An orphaned candidate is retained on error for investigation.
    static func createFromPreservedSource(
        at sourceURL: URL, in directory: URL, now: Int64
    ) throws -> JournalStagingCandidate {
        let original = try SnapshotStore.readForPreservation(at: sourceURL)
        let candidate = try create(source: original, in: directory, now: now)
        // A source change during staging must not return a candidate as if it were current.
        // This second read does not replace the external lock or the future atomic adoption fence.
        let current = try SnapshotStore.readForPreservation(at: sourceURL)
        guard current == original else { throw JournalMigrationError.verificationFailed }
        return candidate
    }
}
