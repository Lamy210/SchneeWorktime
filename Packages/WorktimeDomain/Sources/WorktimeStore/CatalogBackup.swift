import Foundation
import WorktimeDomain

public enum CatalogBackupError: Error, Equatable {
    case invalidArchive, unsupportedVersion, tooLarge
}

/// A validated logical backup candidate. Source identity is for inspection, not for restoring a live store.
public enum CatalogBackup {
    private static let maxPayload = 16 * 1024 * 1024
    private static let maxArchive = 24 * 1024 * 1024

    private struct Archive: Codable {
        let schemaVersion: Int
        let sourceEpoch: UUID
        let revision: Int64
        let payload: Data?
    }

    static func encode(_ snapshot: StoredSnapshot, now: Int64) throws -> Data {
        _ = try validateSnapshot(snapshot, now: now)
        let archive = Archive(
            schemaVersion: 1, sourceEpoch: snapshot.version.epoch,
            revision: snapshot.version.revision, payload: snapshot.payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        guard data.count <= maxArchive else { throw CatalogBackupError.tooLarge }
        return data
    }

    /// Inspect only. Never modifies a live database or credits time based on a copied heartbeat.
    public static func inspect(_ data: Data, now: Int64) throws -> CatalogSession {
        try decodeValidated(data, now: now).session
    }

    static func decodeValidated(
        _ data: Data, now: Int64
    ) throws -> (snapshot: StoredSnapshot, session: CatalogSession) {
        guard data.count <= maxArchive else { throw CatalogBackupError.tooLarge }
        let archive: Archive
        do {
            archive = try JSONDecoder().decode(Archive.self, from: data)
        } catch {
            throw CatalogBackupError.invalidArchive
        }
        guard archive.schemaVersion == 1 else { throw CatalogBackupError.unsupportedVersion }
        let snapshot = StoredSnapshot(
            version: StoreVersion(epoch: archive.sourceEpoch, revision: archive.revision), payload: archive.payload
        )
        return try (snapshot, validateSnapshot(snapshot, now: now))
    }

    private static func validateSnapshot(_ snapshot: StoredSnapshot, now: Int64) throws -> CatalogSession {
        let journal: CatalogJournal
        if let payload = snapshot.payload {
            guard !payload.isEmpty, snapshot.version.revision > 0 else {
                throw CatalogBackupError.invalidArchive
            }
            guard payload.count <= maxPayload else { throw CatalogBackupError.tooLarge }
            do {
                journal = try JSONDecoder().decode(CatalogJournal.self, from: payload)
            } catch {
                throw CatalogPersistenceError.invalidJournal
            }
        } else {
            guard snapshot.version.revision == 0 else { throw CatalogBackupError.invalidArchive }
            journal = CatalogJournal()
        }
        guard Int64(journal.events.count) == snapshot.version.revision else {
            throw CatalogPersistenceError.invalidJournal
        }
        let catalog = try journal.replay(now: now)
        return CatalogSession(version: snapshot.version, catalog: catalog)
    }
}
