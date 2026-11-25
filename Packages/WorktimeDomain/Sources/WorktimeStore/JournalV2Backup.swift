import Foundation
import WorktimeDomain

public enum JournalV2BackupError: Error, Equatable {
    case invalidArchive, unsupportedVersion, tooLarge
}

/// Read-only inspection of an untrusted exported archive. It is not a restoration grant.
public struct JournalV2BackupInspection {
    public let version: StoreVersion
    public let catalog: WorkdayCatalog
    public let eventCount: Int
}

/// Explicit schema-2 export, independent of schema-1 snapshots or migration drafts.
/// Checkpoints are never portable: a copied observation does not prove current work.
/// Archives are untrusted data, not signatures or proof of authenticity.
public enum JournalV2Backup {
    private static let format = "schneeworktime-journal"
    private static let version = 2

    private struct Archive: Codable {
        let format: String
        let schemaVersion: Int
        let sourceEpoch: UUID
        let revision: Int64
        let payloads: [Data]
    }

    /// Exports a *validated* committed generation; does not change the live database.
    static func encode(_ state: JournalV2LiveState, now: Int64) throws -> Data {
        let catalog = try validatedCatalog(
            payloads: state.rows.map(\.payload), revision: state.version.revision, now: now
        )
        guard catalog == state.catalog else { throw JournalMigrationError.verificationFailed }
        let archive = Archive(
            format: format, schemaVersion: version, sourceEpoch: state.version.epoch,
            revision: state.version.revision, payloads: state.rows.map(\.payload)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        guard data.count <= BackupFile.maxBytes else { throw JournalV2BackupError.tooLarge }
        return data
    }

    /// Inspects a bounded archive without creating a DB, mutating records or adopting its source epoch.
    public static func inspect(_ data: Data, now: Int64) throws -> JournalV2BackupInspection {
        guard data.count <= BackupFile.maxBytes else { throw JournalV2BackupError.tooLarge }
        let archive: Archive
        do {
            archive = try JSONDecoder().decode(Archive.self, from: data)
        } catch {
            throw JournalV2BackupError.invalidArchive
        }
        guard archive.format == format else { throw JournalV2BackupError.invalidArchive }
        guard archive.schemaVersion == version else { throw JournalV2BackupError.unsupportedVersion }
        let catalog = try validatedCatalog(
            payloads: archive.payloads, revision: archive.revision, now: now
        )
        return JournalV2BackupInspection(
            version: StoreVersion(epoch: archive.sourceEpoch, revision: archive.revision),
            catalog: catalog, eventCount: archive.payloads.count
        )
    }

    private static func validatedCatalog(
        payloads: [Data], revision: Int64, now: Int64
    ) throws -> WorkdayCatalog {
        guard payloads.count <= JournalRowCodec.maxRows else { throw JournalMigrationError.rowLimit }
        guard revision == Int64(payloads.count) else { throw JournalMigrationError.invalidSequence }
        var remaining = JournalRowCodec.maxTotalBytes
        var rows: [JournalEventRow] = []
        rows.reserveCapacity(payloads.count)
        for (index, payload) in payloads.enumerated() {
            guard !payload.isEmpty, payload.count <= JournalRowCodec.maxRowBytes,
                  payload.count <= remaining else { throw JournalMigrationError.byteLimit }
            remaining -= payload.count
            rows.append(JournalEventRow(sequence: Int64(index + 1), payload: payload))
        }
        let events = try JournalRowCodec.decode(rows, revision: revision)
        var previous: Int64?
        for event in events {
            guard event.now <= now else {
                throw CatalogPersistenceError.futureEvent
            }
            if let previous, event.now < previous {
                throw JournalMigrationError.invalidEvent
            }
            previous = event.now
        }
        return try JournalRowCodec.replay(rows, revision: revision, now: now)
    }
}
