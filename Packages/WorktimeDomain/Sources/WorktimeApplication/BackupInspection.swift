import Foundation
import WorktimeDomain
import WorktimeStore

/// A read-only summary, not a restore authorization or proof of archive authenticity.
public struct BackupInspection: Sendable, Equatable {
    public let revision: Int64
    public let days: Int
    public let corrections: Int
    public let hasActiveDay: Bool
    public let firstStart: Int64?
    public let lastStart: Int64?

    public init(file: URL, now: Int64) throws {
        let session = try CatalogBackup.inspectFile(at: file, now: now)
        revision = session.version.revision
        days = session.catalog.days.count
        corrections = session.catalog.reviewAudit.count
        hasActiveDay = session.catalog.activeID != nil
        firstStart = session.catalog.days.first?.intervals.first?.start
        lastStart = session.catalog.days.last?.intervals.first?.start
    }
}
