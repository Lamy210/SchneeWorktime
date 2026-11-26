import Foundation
import WorktimeStore

public enum JournalV2ConfirmedResetError: Error, Equatable {
    case staleConfirmation, missingConsent
}

/// A read-only preview bound to one owning session and its exact checkpoint.
/// This is logical deletion of the current database, not complete data erasure.
public struct JournalV2ConfirmedReset {
    public let preview: JournalV2ResetPreview
    public let context: JournalV2WorkActionContext
}

public extension JournalV2WorktimeController {
    func previewConfirmedReset(
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> JournalV2ConfirmedReset {
        guard expected == workActionContext else {
            throw JournalV2ConfirmedResetError.staleConfirmation
        }
        let preview = try previewReset(sample: sample)
        return JournalV2ConfirmedReset(preview: preview, context: expected)
    }

    func isCurrent(_ confirmation: JournalV2ConfirmedReset) -> Bool {
        confirmation.context == workActionContext && isCurrent(confirmation.preview)
    }

    /// The caller must hold the owner lock, stop writers and settle cancellation
    /// of owned notifications. Never rebase this destructive confirmation.
    mutating func commitConfirmedReset(
        _ confirmation: JournalV2ConfirmedReset, consent: String, sample: ClockSample
    ) throws {
        guard consent == "削除" else { throw JournalV2ConfirmedResetError.missingConsent }
        guard isCurrent(confirmation) else { throw JournalV2ConfirmedResetError.staleConfirmation }
        try commitReset(confirmation.preview, sample: sample)
    }
}
