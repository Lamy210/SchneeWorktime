import Foundation
import WorktimeDomain
import WorktimeStore

/// A specific observed Journal/Checkpoint generation shown to the user.
/// The token is invalid after any command or checkpoint-only write.
public struct JournalV2WorkActionContext: Sendable, Equatable {
    public let version: StoreVersion
    public let day: Workday?
    public let checkpoint: ObservationCheckpoint?
    public let canOpenWorkday: Bool
    public let canAppend: Bool
}

public enum JournalV2WorkActionError: Error, Equatable {
    case staleContext, insufficientCapacity, invalidTransition
}

public extension JournalV2WorktimeController {
    var workActionContext: JournalV2WorkActionContext {
        JournalV2WorkActionContext(
            version: session.version, day: session.catalog.days.last,
            checkpoint: session.checkpoint,
            canOpenWorkday: session.journalCapacity.canOpenWorkday,
            canAppend: session.journalCapacity.remainingEvents > 0
        )
    }

    /// A UI confirmation cannot be replayed against a different Journal or
    /// checkpoint, even when the revision did not change.
    mutating func performConfirmed(
        _ command: WorkdayCommand, matching expected: JournalV2WorkActionContext,
        sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard expected == workActionContext else {
            throw JournalV2WorkActionError.staleContext
        }
        _ = try repository.revalidate(session, now: sample.wall)
        let hasCapacity = switch command {
        case .clockIn: expected.canOpenWorkday
        default: expected.canAppend
        }
        guard hasCapacity else {
            throw JournalV2WorkActionError.insufficientCapacity
        }
        var proposed = session.catalog
        do {
            try proposed.apply(
                command, at: sample.wall, now: sample.wall,
                expectedRevision: proposed.revision
            )
        } catch is WorkdayError {
            throw JournalV2WorkActionError.invalidTransition
        }
        return try perform(command, sample: sample)
    }
}
