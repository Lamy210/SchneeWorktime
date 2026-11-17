#if os(macOS)
    import SwiftUI
    import WorktimeApplication

    @MainActor
    struct WorktimeHistoryView: View {
        @ObservedObject var model: DesktopModel
        @State private var history: WorktimeHistory?
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("退勤済みの勤務履歴") {
                Text("直近30件。読込時点の保存済み記録です。正式な勤怠集計ではありません。")
                    .font(.caption)
                Button("履歴を読み込む") { reload() }
                    .disabled(model.choosingBackupDestination)
                if let notice {
                    Text(notice).font(.caption)
                }
                if let history {
                    Text("読込日時：\(time(history.loadedAt)) · revision \(history.version.revision)")
                        .font(.caption)
                    Text("\(history.rows.count) / \(history.totalEndedDays)件")
                        .font(.caption)
                    if history.rows.isEmpty {
                        Text("退勤済みの勤務履歴はありません。").font(.caption)
                    }
                    ForEach(history.rows) { row in
                        Divider()
                        rowView(row)
                    }
                    Button("履歴表示を消去") { self.history = nil }
                }
            }
        }

        private func reload() {
            history = nil
            notice = nil
            do {
                history = try model.recentHistory()
                if history == nil {
                    notice = "勤務記録を再読込してください。"
                }
            } catch {
                notice = "勤務履歴を読み込めませんでした。既存記録は変更していません。"
            }
        }

        private func rowView(_ row: WorktimeHistoryRow) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(time(row.startedAt)) 〜 \(time(row.endedAt))").font(.caption)
                Text("実働：\(duration(row.worked))").font(.headline)
                Text("休憩：\(DepartureCountdown.duration(row.rest))")
                Text("目標：\(DepartureCountdown.duration(row.target))")
                Text("日次不足：\(duration(row.remaining))")
                Text("日次超過：\(duration(row.surplus))")
                if row.worked.lowerBound != row.worked.upperBound {
                    Text("要確認：実働の上下限を表示").foregroundStyle(.orange)
                }
                Text("訂正履歴：\(row.corrections)件")
            }
            .font(.caption)
        }

        private func duration(_ range: ClosedRange<Int64>) -> String {
            let lower = DepartureCountdown.duration(range.lowerBound)
            let upper = DepartureCountdown.duration(range.upperBound)
            return lower == upper ? lower : "\(lower)〜\(upper)"
        }

        private func time(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.year().month().day().hour().minute())
        }
    }
#endif
