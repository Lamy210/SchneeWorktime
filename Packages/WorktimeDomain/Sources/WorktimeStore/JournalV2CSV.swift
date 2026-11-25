import Foundation

public extension JournalV2Repository {
    /// Produces the same 14-column CSV schema as the previous catalog exporter,
    /// but only from an exactly revalidated schema-2 journal generation.
    /// Checkpoints are a CAS fence, not exported attendance evidence.
    func makeCSV(now: Int64, matching session: JournalV2Session) throws -> Data {
        let current = try revalidate(session, now: now)
        return try CatalogCSV.encode(catalog: current.catalog, version: current.version)
    }

    /// The destination must be explicitly selected by the caller. The existing
    /// secure publisher refuses overwrites and never modifies the live database.
    func writeCSV(to url: URL, now: Int64, matching session: JournalV2Session) throws {
        let data = try makeCSV(now: now, matching: session)
        try BackupFile.publish(data, to: url)
    }
}
