#if os(macOS)
    import Foundation
    import WorktimeApplication

    extension DesktopModel {
        /// Every page performs a strict SQLite read-only Journal replay.
        /// An external checkpoint-only change also invalidates the displayed page.
        func schemaTwoHistoryPage(
            offset: Int, previous: JournalV2ReadOnlyInspection
        ) throws -> JournalV2ReadOnlyInspection {
            guard !ready, controller == nil, sessionLock != nil,
                  let displayed = schemaTwoInspection,
                  displayed.version == previous.version,
                  displayed.lastObservedAt == previous.lastObservedAt
            else { throw WorktimeHistoryError.stalePage }
            return try JournalV2ReadOnlyInspection(
                url: databaseURL(), now: Self.sample().wall, offset: offset, previous: previous
            )
        }
    }
#endif
