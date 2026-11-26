import Foundation
import WorktimeDomain
import WorktimeStore

/// Bind the immutable repository preview to the owning desktop session.
public struct JournalV2ConfirmedRollback {
    public let id: UUID
    public let proposal: JournalV2RollbackProposal
    public let context: JournalV2WorkActionContext
}

public extension JournalV2WorktimeController {
    func previewConfirmedRollback(
        file: URL, matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> JournalV2ConfirmedRollback {
        guard expected == workActionContext, expected.day?.state == .ended else {
            throw JournalV2WorkActionError.staleContext
        }
        let proposal = try previewRollback(file: file, sample: sample)
        return JournalV2ConfirmedRollback(id: UUID(), proposal: proposal, context: expected)
    }

    func isCurrent(_ confirmation: JournalV2ConfirmedRollback) -> Bool {
        confirmation.context == workActionContext && isCurrent(confirmation.proposal)
    }

    /// The coordinator must have settled cancellation before this entry point.
    /// Do not reopen the candidate file or reuse an earlier owning session.
    mutating func commitConfirmedRollback(
        _ confirmation: JournalV2ConfirmedRollback, preserveCurrentAt destination: URL,
        sample: ClockSample
    ) throws {
        guard isCurrent(confirmation) else { throw JournalV2WorkActionError.staleContext }
        try commitRollback(confirmation.proposal, preserveCurrentAt: destination, sample: sample)
    }
}
