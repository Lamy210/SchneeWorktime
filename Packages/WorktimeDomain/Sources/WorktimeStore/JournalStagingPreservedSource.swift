import Foundation

extension JournalStagingDatabase {
    /// Build an offline schema-2 candidate from an existing schema-1 file without opening it for writes.
    ///
    /// Caller must hold the app's session lock and prevent concurrent writes to the source.
    /// This is not an adoption operation. An orphaned candidate is retained on error for investigation.
    static func createFromPreservedSource(
        at sourceURL: URL, in directory: URL, now: Int64
    ) throws -> JournalStagingCandidate {
        let source = try JournalPreservedSourceCapture.read(at: sourceURL)
        let candidate = try create(
            source: source.snapshot, in: directory, now: now,
            checkpointAnchor: .captured(source.checkpoint)
        )
        // Reject a replaced file even when the new file contains identical snapshot bytes.
        // This does not replace the external lock or the future atomic adoption fence.
        try source.verifyUnchanged(at: sourceURL)
        return JournalStagingCandidate(
            url: candidate.url, draft: candidate.draft,
            fileIdentity: candidate.fileIdentity, capturedSource: source
        )
    }
}
