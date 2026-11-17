#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    struct ReferenceStatusView: View {
        let glance: WorktimeGlance

        var body: some View {
            if let reference = glance.day.profile.reference {
                switch reference.resolution {
                case .disabled:
                    EmptyView()
                case .beforeStart:
                    Text("参考終業：勤務開始前のため不適用").font(.caption)
                case .nonexistent:
                    Text("参考終業：存在しない現地時刻").font(.caption)
                case .ambiguous:
                    Text("参考終業：重複時刻の選択が必要").font(.caption)
                case let .resolved(instant):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("参考終業：\(label(instant, zone: reference.timeZoneID))")
                        Text("勤務開始日：\(reference.logicalDate)・\(reference.timeZoneID)")
                        if let difference = try? glance.referenceDifference() {
                            Text(differenceLabel(difference))
                        }
                    }
                    .font(.caption)
                }
            }
        }

        private func label(_ instant: Int64, zone: String) -> String {
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: Date(timeIntervalSince1970: Double(instant)))
        }

        private func differenceLabel(_ seconds: Int64) -> String {
            if seconds < 0 {
                return "参考時刻まで\((-seconds) / 60)分"
            }
            return "参考時刻から\(seconds / 60)分経過"
        }
    }
#endif
