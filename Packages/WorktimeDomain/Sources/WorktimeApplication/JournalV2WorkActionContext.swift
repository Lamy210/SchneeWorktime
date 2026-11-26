import Foundation
import WorktimeDomain
import WorktimeStore

/// A specific observed Journal/Checkpoint generation shown to the user.
/// Strict confirmations require this exact token. Basic attendance actions may
/// explicitly allow a routine checkpoint advance within the same live session.
public struct JournalV2WorkActionContext: Sendable, Equatable {
    let sessionID: UUID
    public let version: StoreVersion
    public let day: Workday?
    public let checkpoint: ObservationCheckpoint?
    public let canOpenWorkday: Bool
    public let canAppend: Bool

    /// Only an advancing checkpoint in the same live working session can
    /// leave a basic, time-of-confirmation attendance action unchanged.
    public func permitsRoutineObservation(since displayed: Self) -> Bool {
        if self == displayed { return true }
        guard sessionID == displayed.sessionID, version == displayed.version,
              day == displayed.day, day?.state == .working,
              canOpenWorkday == displayed.canOpenWorkday, canAppend == displayed.canAppend,
              let before = displayed.checkpoint, let after = checkpoint,
              before.version == displayed.version, after.version == version,
              before.dayID == after.dayID, after.dayID == day?.id
        else { return false }
        return after.observedAt > before.observedAt
    }
}

public enum JournalV2WorkActionError: Error, Equatable {
    case staleContext, insufficientCapacity, invalidTransition
}

public extension JournalV2WorktimeController {
    var workActionContext: JournalV2WorkActionContext {
        JournalV2WorkActionContext(
            sessionID: confirmationSessionID,
            version: session.version, day: session.catalog.days.last,
            checkpoint: session.checkpoint,
            canOpenWorkday: session.journalCapacity.canOpenWorkday,
            canAppend: session.journalCapacity.remainingEvents > 0
        )
    }

    /// Only basic break/clock-out actions may survive routine local observation.
    /// The current complete repository generation is still revalidated by the
    /// strict entry point; never adopt a checkpoint read from another writer.
    mutating func performConfirmedAfterRoutineObservation(
        _ command: WorkdayCommand, matching expected: JournalV2WorkActionContext,
        sample: ClockSample
    ) throws -> WorktimeGlance? {
        let current = workActionContext
        if expected != current {
            switch command {
            case .startBreak, .clockOut:
                guard current.permitsRoutineObservation(since: expected) else {
                    throw JournalV2WorkActionError.staleContext
                }
                var checked = clock
                guard try checked.advance(to: sample) == nil else {
                    throw JournalV2WorkActionError.staleContext
                }
            default:
                throw JournalV2WorkActionError.staleContext
            }
        }
        return try performConfirmed(command, matching: current, sample: sample)
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
