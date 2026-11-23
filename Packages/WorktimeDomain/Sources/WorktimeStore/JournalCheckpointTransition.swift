import Foundation

/// Read-only checkpoint shape required after a hypothetical schema-2 generation switch.
/// This is neither a verified clock observation nor permission to adopt the candidate.
struct JournalCheckpointTransition: Equatable {
    let candidateVersion: StoreVersion
    let activeDayID: UUID?
    /// A new observation must be strictly later than both the source marker and latest event.
    let observedAfter: Int64

    func validateReplacement(_ marker: ObservationCheckpoint?, now: Int64) throws {
        guard let dayID = activeDayID else {
            guard marker == nil else { throw JournalMigrationError.verificationFailed }
            return
        }
        guard let marker,
              marker.version == candidateVersion,
              marker.dayID == dayID,
              marker.observedAt > observedAfter
        else { throw JournalMigrationError.verificationFailed }
        try JournalCheckpointAnchor.recorded(marker).validate(
            expected: candidateVersion, now: now
        )
    }
}

extension JournalStagingDatabase {
    /// Classify the *necessary* new-epoch checkpoint, without writing a live database.
    /// Caller must hold the source directory/session lock. This does not authorize promotion:
    /// the atomic switch, CAS fencing, and crash recovery remain separate P0 requirements.
    static func inspectCheckpointTransition(
        sourceURL: URL, candidate: JournalStagingCandidate, now: Int64
    ) throws -> JournalCheckpointTransition {
        let inspected = try preflightPinnedCandidate(
            sourceURL: sourceURL, candidate: candidate, now: now
        )
        guard let captured = candidate.capturedSource else {
            throw JournalMigrationError.verificationFailed
        }
        let latestEventTime: Int64 = if let last = inspected.rows.last {
            try JSONDecoder().decode(JournalEvent.self, from: last.payload).now
        } else {
            Int64.min
        }
        let sourceMarkerTime = captured.checkpoint?.observedAt ?? Int64.min
        return JournalCheckpointTransition(
            candidateVersion: inspected.version,
            activeDayID: inspected.catalog.activeID,
            observedAfter: max(latestEventTime, sourceMarkerTime)
        )
    }
}
