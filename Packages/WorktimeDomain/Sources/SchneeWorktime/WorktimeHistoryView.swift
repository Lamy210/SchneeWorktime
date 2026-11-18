#if os(macOS)
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct WorktimeHistoryView: View {
        @ObservedObject var model: DesktopModel
        @State private var history: WorktimeHistory?
        @State private var notice: String?
        @State private var historical: HistoricalReviewContext?

        var body: some View {
            DisclosureGroup("退勤済みの勤務履歴") {
                Text("直近30件。読込時点の保存済み記録です。正式な勤怠集計ではありません。")
                    .font(.caption)
                Button("履歴を読み込む") { reload() }
                    .disabled(model.choosingBackupDestination)
                if let notice {
                    Text(notice).font(.caption)
                }
                historicalSelection
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
                        if model.glance?.day.id != row.id, model.glance?.day.state == .ended {
                            Button("この勤務日の要確認区間") { select(row.id, from: history) }
                                .disabled(model.reviewProposal != nil || model.choosingBackupDestination)
                        }
                    }
                    Button("履歴表示を消去") {
                        self.history = nil
                        historical = nil
                    }
                }
            }
        }

        @ViewBuilder
        private var historicalSelection: some View {
            if let historical, model.reviewProposal == nil {
                Divider()
                Text("選択中の過去勤務日：\(time(historical.glance.day.intervals.first?.start ?? 0))")
                    .font(.headline)
                if model.ready, model.controller?.isCurrent(historical) == true {
                    if historical.glance.reviewableGaps.isEmpty {
                        Text("要確認区間はありません。").font(.caption)
                    } else {
                        ReviewRangeSettingsView(model: model, glance: historical.glance, historical: historical)
                            .id(historical.glance.day.id)
                    }
                } else {
                    Text("履歴が更新されました。履歴を読み込んで再選択してください。").font(.caption)
                }
                Button("過去勤務日の選択を解除") { self.historical = nil }
            }
        }

        private func select(_ dayID: UUID, from history: WorktimeHistory) {
            historical = nil
            notice = nil
            do {
                historical = try model.historicalReviewContext(dayID: dayID, history: history)
            } catch {
                notice = "過去勤務日を選択できません。勤務終了後に最新履歴を読み込んでください。"
            }
        }

        private func reload() {
            historical = nil
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
