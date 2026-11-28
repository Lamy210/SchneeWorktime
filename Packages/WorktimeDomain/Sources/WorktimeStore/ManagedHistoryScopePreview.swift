import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum ManagedHistoryScopeState: Sendable, Equatable {
    case notInitialized, incompleteSetup, inventoried, inconsistent, pendingErasure
}

/// Counts only explicitly registered managed files, never external exports
/// or legacy staging/recovery directories. This is not a deletion grant.
public struct ManagedHistoryScopePreview: Sendable, Equatable {
    public let version: StoreVersion
    public let workdays: Int
    public let corrections: Int
    public let hasActiveWorkday: Bool
    public let state: ManagedHistoryScopeState
    public let registeredBackups: Int
    public let registeredDiagnostics: Int
    public let verifiedFiles: Int
    public let missingFiles: Int
    public let changedFiles: Int
    public let unsafeFiles: Int
    public let unregisteredFiles: Int
}

enum ManagedHistoryScopeReader {
    static func inspect(in root: URL, session: JournalV2Session) throws -> ManagedHistoryScopePreview {
        if try ManagedHistoryStartupFence.hasPending(in: root) {
            return summary(session, state: .pendingErasure)
        }
        let registryURL = root.appendingPathComponent(ManagedHistoryRegistryFile.filename)
        let managedURL = root.appendingPathComponent(ManagedHistoryInventory.directoryName)
        let registryExists = try exists(registryURL)
        let directoryExists = try exists(managedURL)
        guard registryExists, directoryExists else {
            let state: ManagedHistoryScopeState = registryExists || directoryExists ? .incompleteSetup : .notInitialized
            return summary(session, state: state)
        }
        let registry = try ManagedHistoryRegistryFile.load(in: root)
        let inventory = try ManagedHistoryInventoryReader.inspect(applicationDirectory: root, registry: registry)
        guard try !ManagedHistoryStartupFence.hasPending(in: root) else {
            return summary(session, state: .pendingErasure)
        }
        let state: ManagedHistoryScopeState = inventory.isComplete ? .inventoried : .inconsistent
        return summary(session, state: state, registry: registry, inventory: inventory)
    }

    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        let code = errno
        guard code == ENOENT else { throw ManagedHistoryInventoryError.system(code) }
        return false
    }

    private static func summary(
        _ session: JournalV2Session, state: ManagedHistoryScopeState,
        registry: ManagedHistoryRegistry? = nil, inventory: ManagedHistoryInventory? = nil
    ) -> ManagedHistoryScopePreview {
        let entries = registry?.entries ?? []
        let items = inventory?.items ?? []
        return ManagedHistoryScopePreview(
            version: session.version, workdays: session.catalog.days.count,
            corrections: session.catalog.reviewAudit.count, hasActiveWorkday: session.catalog.activeID != nil,
            state: state, registeredBackups: entries.filter { $0.kind == .backup }.count,
            registeredDiagnostics: entries.filter { $0.kind == .diagnostic }.count,
            verifiedFiles: items.filter { $0.status == .verified }.count,
            missingFiles: items.filter { $0.status == .missing }.count,
            changedFiles: items.filter { $0.status == .changed }.count,
            unsafeFiles: items.filter { $0.status == .unsafe }.count,
            unregisteredFiles: items.filter { $0.status == .unregistered }.count
        )
    }
}
