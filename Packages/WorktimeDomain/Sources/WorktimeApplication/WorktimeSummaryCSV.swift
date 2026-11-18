import Foundation

/// A separate, locale-independent personal summary export, not a restorable backup.
public enum WorktimeSummaryCSV {
    public static func encode(_ summary: WorktimeSummary) -> Data {
        let header = [
            "record_type", "period_unit", "timezone", "period_start_utc", "period_end_exclusive_utc",
            "day_start_utc", "workday_count", "worked_lower_seconds", "worked_upper_seconds", "target_seconds",
            "recorded_rest_seconds", "uncertain_workday_count", "shortfall_lower_seconds", "shortfall_upper_seconds",
            "surplus_lower_seconds", "surplus_upper_seconds", "source_epoch", "source_revision", "loaded_at_utc"
        ]
        let unit: String = switch summary.period.unit {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        }
        let prefix = [unit, safeTimezone(summary.period.timeZoneID), String(summary.period.start),
                      String(summary.period.end)]
        let suffix = [summary.version.epoch.uuidString, String(summary.version.revision), String(summary.loadedAt)]
        let totals = [
            "", String(summary.endedDays), String(summary.worked.lowerBound), String(summary.worked.upperBound),
            String(summary.target), String(summary.recordedRest), String(summary.uncertainDays),
            String(summary.dailyShortfall.lowerBound), String(summary.dailyShortfall.upperBound),
            String(summary.dailySurplus.lowerBound), String(summary.dailySurplus.upperBound)
        ]
        var lines = [header, ["summary"] + prefix + totals + suffix]
        for day in summary.daily {
            let fields = [String(day.id), String(day.endedDays), String(day.worked.lowerBound),
                          String(day.worked.upperBound), String(day.target)]
            lines.append(["day"] + prefix + fields + Array(repeating: "", count: 6) + suffix)
        }
        return Data((lines.map { $0.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Even a caller-supplied alias must not introduce a CSV formula or separator.
    private static func safeTimezone(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"'\(escaped)\""
    }
}
