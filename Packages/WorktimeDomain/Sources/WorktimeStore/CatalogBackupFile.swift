import Foundation

extension CatalogRepository {
    /// The caller must obtain explicit destination selection before invoking this method.
    public func writeBackup(to url: URL, now: Int64, expected: StoreVersion) throws {
        let data = try makeBackup(now: now, expected: expected)
        try BackupFile.publish(data, to: url)
    }
}

extension CatalogBackup {
    /// Validate a bounded, privately stored archive without changing any database.
    public static func inspectFile(at url: URL, now: Int64) throws -> CatalogSession {
        let data = try BackupFile.load(url)
        return try inspect(data, now: now)
    }
}
