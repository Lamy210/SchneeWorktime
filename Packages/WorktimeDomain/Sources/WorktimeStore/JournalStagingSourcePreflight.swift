import Foundation
import WorktimeDomain

extension CatalogRepository {
    /// Read-only preflight against a committed schema-1 snapshot. NOT a migration or adoption authorization.
    /// A later live mutation can still invalidate this result; adoption requires a single transactional CAS fence.
    func inspectJournalV2Candidate(_ url: URL, now: Int64) throws -> JournalStagingInspection {
        let committed = try load(now: now)
        let inspected = try JournalStagingDatabase.inspect(url, now: now)
        guard inspected.source == committed.validatedSnapshot,
              inspected.catalog == committed.catalog
        else { throw JournalMigrationError.verificationFailed }
        // Re-read after inspection so an intervening committed change invalidates this preflight.
        // This does not close the TOCTOU window at a future adoption boundary.
        _ = try revalidate(committed, now: now)
        return inspected
    }
}
