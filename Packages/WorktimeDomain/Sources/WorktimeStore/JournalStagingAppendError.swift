import Foundation

/// Post-COMMIT uncertainty: never blindly retry the same event without independent inspection.
enum JournalStagingAppendError: Error, Equatable {
    case committedButUnverified(StoreVersion)
}
