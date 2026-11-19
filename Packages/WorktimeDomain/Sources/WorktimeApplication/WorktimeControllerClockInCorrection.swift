import WorktimeDomain
import WorktimeStore

public enum ClockInInteractionError: Error, Equatable {
    case staleProposal
}

/// Projected values only; never accepted by the committed summary export API.
public struct ClockInSummaryTotals: Sendable, Equatable {
    public let endedDays: Int
    public let worked: ClosedRange<Int64>
    public let target: Int64
    public let dailyShortfall: ClosedRange<Int64>
    public let dailySurplus: ClosedRange<Int64>

    init(_ summary: WorktimeSummary) {
        endedDays = summary.endedDays
        worked = summary.worked
        target = summary.target
        dailyShortfall = summary.dailyShortfall
        dailySurplus = summary.dailySurplus
    }
}

public struct ClockInSummaryImpact: Sendable, Equatable {
    public let period: WorktimeSummaryPeriod
    public let before: ClockInSummaryTotals
    public let after: ClockInSummaryTotals
}

public struct WorktimeClockInProposal: Sendable {
    let stored: StoredClockInCorrection
    public let before: WorktimeGlance
    public let after: WorktimeGlance
    public let summaryImpacts: [ClockInSummaryImpact]

    public var oldStart: Int64 {
        stored.preview.record.oldStart
    }

    public var newStart: Int64 {
        stored.preview.record.newStart
    }

    public var movesSummaryPeriod: Bool {
        summaryImpacts.count > 1
    }
}

/// A preview uses the explicitly selected unit and timezone, not the saved reference timezone.
public struct ClockInSummarySelection: Sendable, Equatable {
    public let unit: WorktimeSummaryUnit
    public let timeZoneID: String

    public init(unit: WorktimeSummaryUnit, timeZoneID: String) {
        self.unit = unit
        self.timeZoneID = timeZoneID
    }

    func impacts(
        _ preview: ClockInCorrectionPreview, before: WorkdayCatalog, after: WorkdayCatalog,
        version: StoreVersion, now: Int64
    ) throws -> [ClockInSummaryImpact] {
        let old = try WorktimeSummaryPeriod(containing: preview.record.oldStart, unit: unit, timeZoneID: timeZoneID)
        let new = try WorktimeSummaryPeriod(containing: preview.record.newStart, unit: unit, timeZoneID: timeZoneID)
        let periods = old == new ? [old] : [old, new].sorted { $0.start < $1.start }
        return try periods.map { period in
            let original = try WorktimeSummary(catalog: before, version: version, period: period, now: now)
            let revised = try WorktimeSummary(catalog: after, version: version, period: period, now: now)
            return ClockInSummaryImpact(
                period: period, before: ClockInSummaryTotals(original), after: ClockInSummaryTotals(revised)
            )
        }
    }
}

public extension WorktimeController {
    func previewClockInCorrection(
        expectedDay: Workday, oldStart: Int64, newStart: Int64, summary: ClockInSummarySelection,
        historical: HistoricalReviewContext? = nil, sample: ClockSample
    ) throws -> WorktimeClockInProposal {
        let stored = try correctionSession(
            expectedDay: expectedDay, historical: historical, sample: sample,
            stale: ClockInInteractionError.staleProposal
        )
        let preview = try stored.previewClockInCorrection(
            dayID: expectedDay.id, oldStart: oldStart, newStart: newStart, now: sample.wall
        )
        var proposed = stored.catalog
        try proposed.commitClockInCorrection(preview.preview, now: sample.wall)
        let before = try WorktimeGlance(catalog: stored.catalog, now: sample.wall, dayID: expectedDay.id)
        let after = try WorktimeGlance(catalog: proposed, now: sample.wall, dayID: expectedDay.id)
        let impacts = try summary.impacts(
            preview.preview, before: stored.catalog, after: proposed, version: stored.version, now: sample.wall
        )
        return WorktimeClockInProposal(stored: preview, before: before, after: after, summaryImpacts: impacts)
    }

    func isCurrent(_ proposal: WorktimeClockInProposal) -> Bool {
        isCurrentCorrection(version: proposal.stored.version, day: proposal.before.day)
    }

    mutating func commitClockInCorrection(
        _ proposal: WorktimeClockInProposal, sample: ClockSample
    ) throws -> WorktimeGlance? {
        try commitCorrection(
            version: proposal.stored.version, day: proposal.before.day, sample: sample,
            stale: ClockInInteractionError.staleProposal
        ) { repository in
            try repository.commitClockInCorrection(proposal.stored, now: sample.wall)
        }
    }
}
