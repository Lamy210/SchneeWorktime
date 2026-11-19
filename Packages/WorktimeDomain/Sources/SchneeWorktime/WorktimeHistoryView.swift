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
                Text("1ページ30件。読込時点の保存済み記録です。正式な勤怠集計ではありません。")
                    .font(.caption)
                Button("履歴を読み込む") { reload() }
                    .disabled(model.choosingBackupDestination)
                if let notice {
                    Text(notice).font(.caption)
                }
                historicalSelection
                if let history {
                    if model.ready, model.controller?.isCurrent(history) == true {
                        pageContent(history)
                    } else {
                        Text("保存版が変わりました。最新の履歴を読み込んでください。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("履歴表示を消去") {
                        self.history = nil
                        historical = nil
                    }
                }
            }
        }

        @ViewBuilder
        private func pageContent(_ page: WorktimeHistory) -> some View {
            Text("読込日時：\(time(page.loadedAt)) · revision \(page.version.revision)")
                .font(.caption)
            pageNavigation(page)
            if page.rows.isEmpty {
                Text("退勤済みの勤務履歴はありません。").font(.caption)
            }
            ForEach(page.rows) { row in
                Divider()
                rowView(row)
                if model.glance?.day.id != row.id {
                    Button("この勤務日の訂正") { select(row.id, from: page) }
                        .disabled(model.reviewProposal != nil || model.choosingBackupDestination)
                }
            }
        }

        private func pageNavigation(_ page: WorktimeHistory) -> some View {
            let first = page.rows.isEmpty ? 0 : page.offset + 1
            let last = page.offset + page.rows.count
            return HStack {
                if let previous = page.previousOffset {
                    Button("新しい履歴") { reload(offset: previous, previous: page) }
                }
                Text("\(first)〜\(last) / \(page.totalEndedDays)")
                    .font(.caption)
                if let next = page.nextOffset {
                    Button("古い履歴") { reload(offset: next, previous: page) }
                }
            }
            .disabled(model.reviewProposal != nil || model.choosingBackupDestination)
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
                    RestEndCorrectionView(
                        model: model, day: historical.glance.day, boundary: .start, historical: historical
                    )
                    .id(historical.glance.day.id)
                    RestEndCorrectionView(model: model, day: historical.glance.day, historical: historical)
                        .id(historical.glance.day.id)
                    ClockOutCorrectionView(model: model, day: historical.glance.day, historical: historical)
                        .id(historical.glance.day.id)
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
                notice = "過去勤務日を選択できません。最新履歴を読み込んでください。"
            }
        }

        private func reload(offset: Int = 0, previous: WorktimeHistory? = nil) {
            historical = nil
            history = nil
            notice = nil
            do {
                history = try model.recentHistory(offset: offset, previous: previous)
                if history == nil {
                    notice = "勤務記録を再読込してください。"
                }
            } catch WorktimeHistoryError.stalePage {
                notice = "履歴が更新されました。最新ページから読み込んでください。"
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
