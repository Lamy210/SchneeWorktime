import Foundation

/// Event-count admission headroom, not a guarantee against disk or payload exhaustion.
public struct JournalCapacity: Sendable, Equatable {
    public let remainingEvents: Int64

    public init(revision: Int64) {
        let limit = Int64(CatalogJournal.maxEvents)
        remainingEvents = limit - min(max(revision, 0), limit)
    }

    public var shouldWarn: Bool {
        remainingEvents <= 500
    }

    public var canOpenWorkday: Bool {
        remainingEvents > 100
    }

    /// With an active day, reserve the last two slots for observation and clock-out.
    public var isExitReserve: Bool {
        remainingEvents <= 2
    }
}

extension JournalCapacity {
    func allowsActiveMutation(_ action: JournalAction) -> Bool {
        switch action {
        case .command(.clockOut, at: _):
            remainingEvents > 0
        case .observation:
            remainingEvents > 1
        default:
            !isExitReserve
        }
    }
}

public extension CatalogSession {
    var journalCapacity: JournalCapacity {
        JournalCapacity(revision: version.revision)
    }
}

extension JournalCommand {
    var opensWorkday: Bool {
        switch self {
        case .clockIn, .clockInWithReference, .resume: true
        case .startBreak, .endBreak, .clockOut: false
        }
    }
}
