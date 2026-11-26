import Foundation
import WorktimeDomain

/// Settings confirmed before clock-in; the reference Instant is resolved only
/// from the actual clock-in sample, never from the time the UI was opened.
public struct JournalV2ClockInSettings: Sendable, Equatable {
    public let profile: WorkdayProfile
    public let timeZoneID: String
    public let wallTime: ReferenceWallTime?

    public init(profile: WorkdayProfile, timeZoneID: String, wallTime: ReferenceWallTime?) {
        self.profile = profile
        self.timeZoneID = timeZoneID
        self.wallTime = wallTime
    }
}

public enum JournalV2ClockInSettingsError: Error, Equatable {
    case invalidReference
}

public extension JournalV2WorktimeController {
    mutating func performConfirmedClockIn(
        id: UUID, displayed: JournalV2ClockInSettings, current: JournalV2ClockInSettings,
        matching expected: JournalV2WorkActionContext, sample: ClockSample
    ) throws -> WorktimeGlance? {
        guard displayed == current, expected == workActionContext else {
            throw JournalV2WorkActionError.staleContext
        }
        let captured: WorkdayProfile
        do {
            captured = try displayed.profile.capturingReference(
                at: sample.wall, timeZoneID: displayed.timeZoneID, wallTime: displayed.wallTime
            )
        } catch is ReferenceTimeError {
            throw JournalV2ClockInSettingsError.invalidReference
        }
        return try performConfirmed(.clockIn(id: id, profile: captured), matching: expected, sample: sample)
    }
}
