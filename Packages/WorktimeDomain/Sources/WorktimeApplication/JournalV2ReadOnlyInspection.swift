import Foundation
import WorktimeDomain
import WorktimeStore

/// Validated, immutable snapshot for the limited schema-2 desktop history screen.
/// It does not start a work interval, recover gaps, save a checkpoint or schedule notifications.
public struct JournalV2ReadOnlyInspection {
    public let version: StoreVersion
    public let loadedAt: Int64
    public let workdays: Int
    public let endedDays: Int
    public let corrections: Int
    public let activeDay: Workday?
    public let lastObservedAt: Int64?
    public let history: WorktimeHistory

    private let checkpoint: ObservationCheckpoint?

    public init(
        url: URL, now: Int64, offset: Int = 0, previous: JournalV2ReadOnlyInspection? = nil
    ) throws {
        let current = try JournalV2Repository.inspectReadOnly(url: url, now: now)
        if let previous {
            guard previous.version == current.version, previous.checkpoint == current.checkpoint else {
                throw WorktimeHistoryError.stalePage
            }
        } else if offset != 0 {
            throw WorktimeHistoryError.stalePage
        }
        version = current.version
        loadedAt = now
        workdays = current.catalog.days.count
        endedDays = current.catalog.days.filter { $0.state == .ended }.count
        corrections = current.catalog.reviewAudit.count
        activeDay = current.catalog.days.last.flatMap { $0.state == .ended ? nil : $0 }
        lastObservedAt = current.checkpoint?.observedAt
        checkpoint = current.checkpoint
        history = try WorktimeHistory(
            catalog: current.catalog, version: current.version, now: now, offset: offset
        )
    }
}
