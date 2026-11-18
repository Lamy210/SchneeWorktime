#if os(macOS)
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        func captureReference(for command: WorkdayCommand, at instant: Int64) throws -> WorkdayCommand {
            guard case let .clockIn(id, profile) = command else { return command }
            return try .clockIn(id: id, profile: capturedProfile(profile, at: instant))
        }

        func capturedProfile(_ profile: WorkdayProfile, at instant: Int64) throws -> WorkdayProfile {
            let wallTime = try ReferencePreferences.wallTime()
            return try profile.capturingReference(
                at: instant, timeZoneID: TimeZone.current.identifier, wallTime: wallTime
            )
        }
    }
#endif
