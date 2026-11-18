import Foundation
import WorktimeStore

/// The canonical operation was accepted by the repository, but its auxiliary observation write failed.
public struct CommittedCheckpointError: Error, Equatable {
    public let version: StoreVersion
}

extension CatalogRepository {
    func persistCheckpoint(dayID: UUID, at instant: Int64, version: StoreVersion, afterMutation: Bool) throws {
        do {
            try saveObservationCheckpoint(dayID: dayID, observedAt: instant, expected: version)
        } catch {
            if afterMutation { throw CommittedCheckpointError(version: version) }
            throw error
        }
    }
}
