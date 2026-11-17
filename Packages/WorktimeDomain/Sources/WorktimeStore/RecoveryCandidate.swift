import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum RecoveryCandidateError: Error, Equatable {
    case unsafeDirectory, verificationFailed, system(Int32)
}

public struct RecoveryCandidate: Sendable {
    public let databaseURL: URL
    public let sourceVersion: StoreVersion
    public let candidateVersion: StoreVersion
}

public extension CatalogBackup {
    /// Explicit staging operation only. The caller supplies a trusted private directory.
    /// No live database is replaced, and no checkpoint or original epoch is copied.
    static func createRecoveryCandidate(
        _ data: Data, in directory: URL, now: Int64
    ) throws -> RecoveryCandidate {
        let decoded = try decodeValidated(data, now: now)
        var info = stat()
        guard directory.isFileURL, lstat(directory.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else { throw RecoveryCandidateError.unsafeDirectory }
        let staging = directory.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw RecoveryCandidateError.system(errno) }
        // A failed or interrupted operation may leave a private candidate directory for explicit inspection.
        // No startup code automatically adopts files from this directory.
        let url = staging.appendingPathComponent("worktime.sqlite")
        let store = try SnapshotStore(url: url, createIfMissing: true)
        guard chmod(url.path, 0o600) == 0 else { throw RecoveryCandidateError.system(errno) }
        let empty = try store.load()
        let version = try store.seedRecovery(decoded.snapshot, expected: empty.version)
        let reloaded = try CatalogRepository(url: url).load(now: now)
        guard reloaded.version == version, reloaded.catalog == decoded.session.catalog,
              version.epoch != decoded.snapshot.version.epoch,
              try store.loadObservationCheckpoint(expected: version) == nil
        else { throw RecoveryCandidateError.verificationFailed }
        return RecoveryCandidate(
            databaseURL: url, sourceVersion: decoded.snapshot.version, candidateVersion: version
        )
    }
}
