import Foundation
import WorktimeDomain

/// Read-only observation after an uncertain offline append. None of these states permits
/// a blind retry or authorizes adopting the staged database.
enum JournalStagingAppendOutcome: Equatable {
    case matchingAppendObserved(StoreVersion)
    case appendNotObserved(StoreVersion)
    case indeterminate
}

extension JournalStagingDatabase {
    /// Classifies one possible append after an ambiguous SQLite outcome.
    /// The caller must still hold the original session/directory lock.
    /// Only the first append after creating the candidate has a pinned, byte-exact
    /// pre-append prefix. Later revisions need a separate immutable attempt receipt.
    static func inspectUncertainOfflineAppend(
        _ event: JournalEvent, sourceURL: URL, candidate: JournalStagingCandidate,
        expected: StoreVersion, now: Int64
    ) -> JournalStagingAppendOutcome {
        guard event.now <= now,
              expected.epoch == candidate.draft.candidateVersion.epoch,
              expected.revision == candidate.draft.candidateVersion.revision,
              expected.revision < Int64(JournalRowCodec.maxRows)
        else { return .indeterminate }

        do {
            let inspection = try preflightPinnedCandidate(
                sourceURL: sourceURL, candidate: candidate, now: now
            )
            guard inspection.version.epoch == expected.epoch else { return .indeterminate }
            // The pinned candidate draft represents the state before the only attempt
            // this legacy API can classify. Invalid attempts must not look "not observed".
            let prefixRows = candidate.draft.rows
            let prefixCatalog = try JournalRowCodec.replay(
                prefixRows, revision: expected.revision, now: now
            )
            let attemptedRow = try JournalStagingAppendValidation.validate(
                event, rows: prefixRows, catalog: prefixCatalog,
                expected: expected, now: now
            ).row
            if inspection.version == expected {
                // At this instant the expected append has not appeared. No automatic retry.
                return .appendNotObserved(inspection.version)
            }
            guard inspection.version.revision == expected.revision + 1,
                  inspection.rows.count == Int(inspection.version.revision)
            else { return .indeterminate }
            guard inspection.rows.last == attemptedRow else { return .indeterminate }
            // Identity and source/anchor/row-prefix checks are performed by pinned preflight.
            return .matchingAppendObserved(inspection.version)
        } catch {
            // Corruption, changed identity, unknown source generation and I/O errors fail closed.
            return .indeterminate
        }
    }
}
