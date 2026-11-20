import Foundation

public extension CatalogRepository {
    /// The caller must obtain explicit destination selection before invoking this method.
    func writeBackup(to url: URL, now: Int64, expected: StoreVersion) throws {
        let data = try makeBackup(now: now, expected: expected)
        try BackupFile.publish(data, to: url)
    }
}

public extension CatalogBackup {
    /// Preserve one committed schema-1 snapshot without opening a writable repository.
    /// Caller must hold the source directory lock; no checkpoint is copied and no recovery is attempted.
    @discardableResult
    static func writePreservationBackup(from source: URL, to destination: URL, now: Int64) throws -> StoreVersion {
        let canonical = try DatabaseFileGuard.canonicalURL(source)
        let sourceDirectory = canonical.deletingLastPathComponent().pathComponents
        let destinationDirectory = destination.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        guard !destinationDirectory.starts(with: sourceDirectory) else { throw BackupFileError.invalidDestination }
        let snapshot = try SnapshotStore.readForPreservation(at: canonical)
        let archive = try encode(snapshot, now: now)
        try BackupFile.publish(archive, to: destination)
        return snapshot.version
    }

    /// Validate a bounded, privately stored archive without changing any database.
    static func inspectFile(at url: URL, now: Int64) throws -> CatalogSession {
        let data = try BackupFile.load(url)
        return try inspect(data, now: now)
    }
}
