#if os(macOS)
    import Foundation
    import WorktimeApplication

    extension DesktopModel {
        func databaseURL() throws -> URL {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )
            return support.appendingPathComponent("SchneeWorktime", isDirectory: true)
                .appendingPathComponent("worktime.sqlite")
        }

        static func sample() throws -> ClockSample {
            guard let wall = Int64(exactly: Date().timeIntervalSince1970.rounded(.down)) else {
                throw ApplicationClockError.invalidSample
            }
            return try ClockSample(wall: wall, uptime: ProcessInfo.processInfo.systemUptime)
        }
    }
#endif
