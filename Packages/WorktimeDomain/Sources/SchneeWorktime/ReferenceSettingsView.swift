#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeDomain

    enum ReferencePreferences {
        static func wallTime() throws -> ReferenceWallTime? {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "referenceEnabled") == nil || defaults.bool(forKey: "referenceEnabled")
            else { return nil }
            let hour = defaults.object(forKey: "referenceHour") == nil ? 18 : defaults.integer(forKey: "referenceHour")
            let minute = defaults.integer(forKey: "referenceMinute")
            let offset = defaults.integer(forKey: "referenceDayOffset")
            let repeated: RepeatedWallTime? = switch defaults.string(forKey: "referenceOccurrence") {
            case "earlier": .earlier
            case "later": .later
            default: nil
            }
            return try ReferenceWallTime(hour: hour, minute: minute, dayOffset: offset, repeatedTime: repeated)
        }
    }

    struct ReferenceSettingsView: View {
        @AppStorage("referenceEnabled") private var enabled = true
        @AppStorage("referenceHour") private var hour = 18
        @AppStorage("referenceMinute") private var minute = 0
        @AppStorage("referenceDayOffset") private var offset = 0
        @AppStorage("referenceOccurrence") private var occurrence = "unset"

        var body: some View {
            VStack(alignment: .leading) {
                Toggle("参考終業時刻を使用", isOn: $enabled)
                if enabled {
                    Stepper("時：\(hour)", value: $hour, in: 0 ... 23)
                    Stepper("分：\(minute)", value: $minute, in: 0 ... 59)
                    Picker("参考終業の日付", selection: $offset) {
                        Text("勤務開始日").tag(0)
                        Text("勤務開始日の翌日").tag(1)
                    }
                    Picker("夏時間の重複時刻", selection: $occurrence) {
                        Text("未選択（要確認）").tag("unset")
                        Text("早い方").tag("earlier")
                        Text("遅い方").tag("later")
                    }
                    Text("勤務開始時のタイムゾーンで固定します。実働目標や法定残業の判定とは独立です。")
                        .font(.caption)
                }
            }
        }
    }
#endif
