import Foundation

extension JournalCheckpointAnchor {
    /// A structurally valid marker must also describe the active day at its recorded time.
    /// It does not grant authority to adopt a candidate or prove worked time.
    func validate(source: StoredSnapshot, now: Int64) throws {
        try validate(expected: source.version, now: now)
        guard case let .recorded(marker) = self else { return }
        do {
            let atObservation = try CatalogBackup.validateSnapshot(source, now: marker.observedAt)
            guard atObservation.catalog.activeID == marker.dayID else {
                throw JournalMigrationError.verificationFailed
            }
        } catch {
            throw JournalMigrationError.verificationFailed
        }
    }
}
