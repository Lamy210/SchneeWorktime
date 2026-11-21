import Foundation

/// A read-only source observation. A matching snapshot alone cannot detect file replacement
/// with an identical copy, so the physical file identity must also remain stable.
struct JournalPreservedSourceCapture {
    let snapshot: StoredSnapshot
    let identity: DatabaseFileGuard.Identity

    static func read(at url: URL) throws -> JournalPreservedSourceCapture {
        let before = try DatabaseFileGuard.preservationIdentity(url)
        let snapshot = try SnapshotStore.readForPreservation(at: url)
        guard try DatabaseFileGuard.preservationIdentity(url) == before else {
            throw DatabaseFileError.unsafeFile
        }
        return JournalPreservedSourceCapture(snapshot: snapshot, identity: before)
    }

    func verifyUnchanged(at url: URL) throws {
        let current = try Self.read(at: url)
        guard identity == current.identity else { throw DatabaseFileError.unsafeFile }
        guard snapshot == current.snapshot else { throw JournalMigrationError.verificationFailed }
    }
}
