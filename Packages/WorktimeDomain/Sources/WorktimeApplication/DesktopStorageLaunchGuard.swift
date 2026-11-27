import Foundation
import WorktimeStore

public enum DesktopStorageLaunchDecision: Sendable, Equatable {
    case legacyDevelopmentOnly
    case missingDatabase
    case schemaTwoAwaitingUI
    case legacyRequiresPreservation
    case unknownRequiresPreservation
    case newInstallRequiresSchemaTwoUI
}

public enum DesktopStorageLaunchError: Error, Equatable {
    case pendingManagedErasure
}

/// Before the v1 UI cutover, a release build must never create or write schema-1.
/// Developer-only compatibility is explicit and may not enter the release path.
/// A schema-2 version header does not imply Journal validity, and never enables
/// the old schema-1 controller, notifications or maintenance actions.
public enum DesktopStorageLaunchGuard {
    public static func decide(
        url: URL, createIfMissing: Bool, allowLegacyDevelopment: Bool
    ) throws -> DesktopStorageLaunchDecision {
        guard try !ManagedHistoryStartupFence.hasPending(in: url.deletingLastPathComponent()) else {
            throw DesktopStorageLaunchError.pendingManagedErasure
        }
        switch try WorktimeDatabaseFormatProbe.inspect(url: url) {
        case .missing:
            if createIfMissing {
                return allowLegacyDevelopment ? .legacyDevelopmentOnly : .newInstallRequiresSchemaTwoUI
            }
            return .missingDatabase
        case .schemaOne:
            return allowLegacyDevelopment ? .legacyDevelopmentOnly : .legacyRequiresPreservation
        case .schemaTwo:
            return .schemaTwoAwaitingUI
        case .unknown:
            return .unknownRequiresPreservation
        }
    }
}
