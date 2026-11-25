import Foundation
import WorktimeDomain

/// A bounded, locale-independent export of the committed catalog.
/// All timestamps are UTC Unix seconds. Open interval ends remain empty.
public enum CatalogCSV {
    private static let header = [
        "record_type", "day_id", "day_revision", "state", "kind",
        "start_utc_epoch_seconds", "end_utc_epoch_seconds", "target_seconds", "expected_rest_seconds",
        "correction_revision", "observation_generation", "reviewed_at_utc_epoch_seconds",
        "source_epoch", "source_revision"
    ]

    public static func encode(_ session: CatalogSession) throws -> Data {
        try encode(catalog: session.catalog, version: session.version)
    }

    /// Shared schema-independent CSV rendering; the caller must validate the live store first.
    public static func encode(catalog: WorkdayCatalog, version: StoreVersion) throws -> Data {
        var data = Data()
        try append(header, to: &data)
        let epoch = version.epoch.uuidString
        let revision = String(version.revision)
        try append(["snapshot"] + Array(repeating: "", count: 11) + [epoch, revision], to: &data)
        for day in catalog.days {
            let prefix = [day.id.uuidString, String(day.revision), state(day.state)]
            let profile = [String(day.profile.target), String(day.profile.expectedRest)]
            for interval in day.intervals {
                let times = [String(interval.start), interval.end.map(String.init) ?? ""]
                let fields = ["interval"] + prefix + [kind(interval.kind)] + times + profile
                try append(fields + ["", "", "", epoch, revision], to: &data)
            }
            for gap in catalog.observations[day.id] ?? [] {
                let fields = ["unverified"] + prefix + ["", String(gap.start), String(gap.end)] + profile
                try append(fields + ["", "", "", epoch, revision], to: &data)
            }
        }
        for audit in catalog.reviewAudit {
            let review = audit.review
            let recordType = switch audit.origin {
            case .observation: "correction"
            case .recordedRestEnd: "rest_end_correction"
            case .recordedRestStart: "rest_start_correction"
            case .recordedClockOut: "clock_out_correction"
            case .recordedClockIn: "clock_in_correction"
            }
            let fields = [
                recordType, audit.dayID.uuidString, "", "", classification(review.classification),
                String(review.selection.start), String(review.selection.end), "", "",
                String(audit.revision), String(audit.observationGeneration), String(review.reviewedAt),
                epoch, revision
            ]
            try append(fields, to: &data)
        }
        return data
    }

    private static func append(_ fields: [String], to data: inout Data) throws {
        // Fields are fixed tokens, UUIDs and integers only; no user-provided formula or free text.
        let line = fields.joined(separator: ",") + "\r\n"
        guard line.utf8.count <= BackupFile.maxBytes - data.count else { throw BackupFileError.tooLarge }
        data.append(contentsOf: line.utf8)
    }

    private static func state(_ value: WorkdayState) -> String {
        switch value {
        case .working: "working"
        case .onBreak: "on_break"
        case .ended: "ended"
        }
    }

    private static func kind(_ value: IntervalKind) -> String {
        switch value {
        case .work: "work"
        case .rest: "rest"
        case .gap: "gap"
        }
    }

    private static func classification(_ value: ReviewClassification) -> String {
        switch value {
        case .work: "work"
        case .rest: "rest"
        case .gap: "gap"
        }
    }
}

public extension CatalogRepository {
    /// Call only after explicit destination selection. The live store is never mutated.
    func writeCSV(to url: URL, now: Int64, expected: StoreVersion) throws {
        let session = try load(now: now)
        guard session.version == expected else { throw SnapshotStoreError.staleVersion }
        let data = try CatalogCSV.encode(session)
        try BackupFile.publish(data, to: url)
    }
}
