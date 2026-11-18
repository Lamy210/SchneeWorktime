#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication

    struct WorktimeDailyChart: View {
        let summary: WorktimeSummary

        private var scale: Double {
            Double(max(1, summary.daily.map { max($0.worked.upperBound, $0.target) }.max() ?? 0))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("始業日別の実働").font(.headline)
                Text("青：確認済み下限／橙：未確認分／線：日次目標の合計")
                    .font(.caption)
                Text("退勤済み記録のない日は表示しません。休日・欠勤の判定ではありません。")
                    .font(.caption)
                if summary.daily.isEmpty {
                    Text("対象期間に退勤済み記録がありません。").font(.caption)
                }
                ForEach(summary.daily) { day in
                    row(day)
                }
            }
        }

        private func row(_ day: WorktimeDailySummary) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(dateLabel(day.id)) · \(day.endedDays)件")
                    .font(.caption)
                Text("実働：\(duration(day.worked))／目標：\(DepartureCountdown.duration(day.target))")
                    .font(.caption)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let lower = width * CGFloat(Double(day.worked.lowerBound) / scale)
                    let upper = width * CGFloat(Double(day.worked.upperBound) / scale)
                    let target = width * CGFloat(Double(day.target) / scale)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.blue).frame(width: lower)
                            Rectangle().fill(Color.orange).frame(width: max(0, upper - lower))
                        }
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2)
                            .offset(x: min(max(0, width - 2), target))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                .accessibilityHidden(true)
            }
        }

        private func duration(_ range: ClosedRange<Int64>) -> String {
            let lower = DepartureCountdown.duration(range.lowerBound)
            let upper = DepartureCountdown.duration(range.upperBound)
            return lower == upper ? lower : "\(lower)〜\(upper)"
        }

        private func dateLabel(_ instant: Int64) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: summary.period.timeZoneID)
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: Date(timeIntervalSince1970: Double(instant)))
        }
    }
#endif
