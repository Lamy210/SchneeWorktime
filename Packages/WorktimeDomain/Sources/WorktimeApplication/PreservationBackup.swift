import Foundation
import WorktimeStore

/// Explicit export of committed history without a controller or a clock observation mutation.
public enum PreservationBackup {
    public static func write(from database: URL, to destination: URL, now: Int64) throws {
        try CatalogBackup.writePreservationBackup(from: database, to: destination, now: now)
    }
}
