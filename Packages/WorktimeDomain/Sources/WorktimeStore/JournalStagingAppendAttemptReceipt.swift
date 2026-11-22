import Foundation
import WorktimeDomain

/// An ephemeral, read-only record of the candidate immediately BEFORE one append attempt.
/// Losing this value (for example after a crash) leaves the outcome indeterminate.
/// It is not a retry token, a persistent recovery record, or permission to adopt the candidate.
struct JournalStagingAppendAttemptReceipt {
    fileprivate let sourceURL: URL
    fileprivate let candidateURL: URL
    fileprivate let sourceIdentity: DatabaseFileGuard.Identity
    fileprivate let candidateIdentity: DatabaseFileGuard.Identity
    fileprivate let sourceSnapshot: StoredSnapshot
    fileprivate let checkpointAnchor: JournalCheckpointAnchor
    fileprivate let expected: StoreVersion
    fileprivate let prefixRows: [JournalEventRow]
    fileprivate let attemptedRow: JournalEventRow
    fileprivate let eventTime: Int64

    fileprivate init(
        sourceURL: URL, candidate: JournalStagingCandidate,
        preserved: JournalPreservedSourceCapture,
        inspected: JournalStagingInspection,
        attemptedRow: JournalEventRow, eventTime: Int64
    ) throws {
        self.sourceURL = try DatabaseFileGuard.canonicalURL(sourceURL)
        candidateURL = try DatabaseFileGuard.canonicalURL(candidate.url)
        sourceIdentity = preserved.identity
        candidateIdentity = candidate.fileIdentity
        sourceSnapshot = preserved.snapshot
        checkpointAnchor = .captured(preserved.checkpoint)
        expected = inspected.version
        prefixRows = inspected.rows
        self.attemptedRow = attemptedRow
        self.eventTime = eventTime
    }
}

extension JournalStagingDatabase {
    /// Capture a byte-exact pre-append prefix while holding the caller's session/directory lock.
    /// Read-only; callers must create this BEFORE attempting the append, not after an error.
    static func captureOfflineAppendAttempt(
        _ event: JournalEvent, sourceURL: URL, candidate: JournalStagingCandidate,
        expected: StoreVersion, now: Int64
    ) throws -> JournalStagingAppendAttemptReceipt {
        guard event.now <= now else { throw CatalogPersistenceError.futureEvent }
        guard expected.revision < Int64(JournalRowCodec.maxRows) else {
            throw JournalMigrationError.rowLimit
        }
        guard let preserved = candidate.capturedSource else {
            throw JournalMigrationError.verificationFailed
        }
        let inspected = try preflightPinnedCandidate(
            sourceURL: sourceURL, candidate: candidate, now: now
        )
        guard inspected.version == expected else { throw SnapshotStoreError.staleVersion }
        let row = try JournalRowCodec.encode(event, sequence: expected.revision + 1)
        return try JournalStagingAppendAttemptReceipt(
            sourceURL: sourceURL, candidate: candidate,
            preserved: preserved, inspected: inspected,
            attemptedRow: row, eventTime: event.now
        )
    }

    /// Reinspect one uncertain append without writing or authorizing a retry.
    /// Exact prefix equality is checked even for attempts after the first append.
    static func inspectUncertainOfflineAppend(
        _ receipt: JournalStagingAppendAttemptReceipt, sourceURL: URL,
        candidate: JournalStagingCandidate, now: Int64
    ) -> JournalStagingAppendOutcome {
        guard receipt.eventTime <= now,
              let preserved = candidate.capturedSource,
              preserved.identity == receipt.sourceIdentity,
              preserved.snapshot == receipt.sourceSnapshot,
              candidate.fileIdentity == receipt.candidateIdentity,
              receipt.expected.epoch == candidate.draft.candidateVersion.epoch,
              receipt.expected.revision >= candidate.draft.candidateVersion.revision
        else { return .indeterminate }

        do {
            guard try DatabaseFileGuard.canonicalURL(sourceURL) == receipt.sourceURL,
                  try DatabaseFileGuard.canonicalURL(candidate.url) == receipt.candidateURL
            else { return .indeterminate }
            let inspected = try preflightPinnedCandidate(
                sourceURL: sourceURL, candidate: candidate, now: now
            )
            guard inspected.version.epoch == receipt.expected.epoch,
                  inspected.source == receipt.sourceSnapshot,
                  inspected.checkpointAnchor == receipt.checkpointAnchor,
                  inspected.rows.count >= receipt.prefixRows.count,
                  Array(inspected.rows.prefix(receipt.prefixRows.count)) == receipt.prefixRows
            else { return .indeterminate }

            if inspected.version == receipt.expected {
                guard inspected.rows == receipt.prefixRows else { return .indeterminate }
                return .appendNotObserved(inspected.version)
            }
            guard inspected.version.revision == receipt.expected.revision + 1,
                  inspected.rows.count == receipt.prefixRows.count + 1,
                  inspected.rows.last == receipt.attemptedRow
            else { return .indeterminate }
            return .matchingAppendObserved(inspected.version)
        } catch {
            return .indeterminate
        }
    }
}
