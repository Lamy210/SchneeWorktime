import Foundation

/// A read-only source observation. A matching snapshot alone cannot detect file replacement
/// with an identical copy, so the physical file identity must also remain stable.
struct JournalPreservedSourceCapture {
    let snapshot: StoredSnapshot
    let checkpoint: ObservationCheckpoint?
    let identity: DatabaseFileGuard.Identity

    static func read(at url: URL) throws -> JournalPreservedSourceCapture {
        let before = try DatabaseFileGuard.preservationIdentity(url)
        let observed = try SnapshotStore.readPreservationState(at: url)
        if let checkpoint = observed.checkpoint {
            try validateCheckpoint(checkpoint, against: observed.snapshot)
        }
        guard try DatabaseFileGuard.preservationIdentity(url) == before else {
            throw DatabaseFileError.unsafeFile
        }
        return JournalPreservedSourceCapture(
            snapshot: observed.snapshot, checkpoint: observed.checkpoint, identity: before
        )
    }

    /// A marker is only a timestamp bound for the currently open day, not proof of worked time.
    private static func validateCheckpoint(
        _ checkpoint: ObservationCheckpoint, against snapshot: StoredSnapshot
    ) throws {
        guard checkpoint.version == snapshot.version else { throw ObservationCheckpointError.invalid }
        do {
            let session = try CatalogBackup.validateSnapshot(snapshot, now: checkpoint.observedAt)
            guard session.catalog.activeID == checkpoint.dayID else {
                throw ObservationCheckpointError.invalid
            }
        } catch {
            throw ObservationCheckpointError.invalid
        }
    }

    func verifyUnchanged(at url: URL) throws {
        let current = try Self.read(at: url)
        guard identity == current.identity else { throw DatabaseFileError.unsafeFile }
        guard snapshot == current.snapshot, checkpoint == current.checkpoint else {
            throw JournalMigrationError.verificationFailed
        }
    }
}
