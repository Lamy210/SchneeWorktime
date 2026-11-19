#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct ClockInCorrectionView: View {
        @ObservedObject var model: DesktopModel
        let day: Workday
        var historical: HistoricalReviewContext?
        @State private var offsetMinutes = "-30"
        @State private var unit: WorktimeSummaryUnit = .day
        @State private var proposal: WorktimeClockInProposal?
        @State private var notice: String?

        var body: some View {
            if day.state == .ended, let first = day.intervals.first {
                if first.kind == .work, first.end != nil {
                    DisclosureGroup("記録済み始業時刻の訂正") {
                        editor(first.start)
                        if let proposal {
                            confirmation(proposal)
                        }
                        if let notice {
                            Text(notice).font(.caption)
                        }
                    }
                    .disabled(!model.ready || model.choosingBackupDestination || model.reviewProposal != nil)
                } else {
                    Text("先頭が勤務区間ではない記録は始業訂正の対象外です。").font(.caption)
                }
            }
        }

        private func editor(_ start: Int64) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("元の始業：\(ClockInCorrectionLabels.time(start, zone: TimeZone.current.identifier))")
                Text("捕捉勤務日・参考終業の解決結果を変える訂正はできません。").font(.caption)
                if day.profile.reference == nil {
                    Text("捕捉参考情報がない旧記録。推定で補完しません。").font(.caption)
                }
                TextField("変更分（分、前倒しは負数）", text: $offsetMinutes)
                Picker("集計確認の単位", selection: $unit) {
                    Text("日").tag(WorktimeSummaryUnit.day)
                    Text("週").tag(WorktimeSummaryUnit.week)
                    Text("月").tag(WorktimeSummaryUnit.month)
                }
                .pickerStyle(.segmented)
                Text("集計は訂正案作成時のシステムタイムゾーンを使用します。").font(.caption)
                Button("始業訂正案を確認") { prepare(start) }
            }
            .onChange(of: offsetMinutes) { _, _ in proposal = nil }
            .onChange(of: unit) { _, _ in proposal = nil }
        }

        private func confirmation(_ value: WorktimeClockInProposal) -> some View {
            let zone = value.summaryImpacts.first?.period.timeZoneID ?? "UTC"
            let current = model.controller?.isCurrent(value) == true
            return VStack(alignment: .leading, spacing: 6) {
                Text("訂正案（未保存）").font(.headline)
                Text("タイムゾーン：\(zone)")
                Text("始業：\(ClockInCorrectionLabels.time(value.oldStart, zone: zone))")
                Text("変更後：\(ClockInCorrectionLabels.time(value.newStart, zone: zone))")
                Text("実働：\(worked(value.before)) → \(worked(value.after))")
                Text("捕捉勤務日と参考終業時刻は維持します。")
                if value.movesSummaryPeriod {
                    Text("集計期間が移動します。移動元と移動先の両方を確認してください。")
                        .foregroundStyle(.orange)
                }
                ForEach(value.summaryImpacts, id: \.period.start) { impact in
                    ClockInSummaryImpactView(impact: impact)
                }
                Text("変更範囲の勤務実績を確認してください。日次不足と超過は相殺しません。")
                Button("始業訂正を確定") { confirm(value) }
                    .disabled(!current)
                Button("キャンセル") { proposal = nil }
                if !current {
                    Text("保存版が変更されました。訂正案を再作成してください。")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }

        private func prepare(_ start: Int64) {
            proposal = nil
            notice = nil
            guard let minutes = Int64(offsetMinutes), minutes != 0, (-1440 ... 1440).contains(minutes) else {
                notice = "±1440分以内の0以外の整数を指定してください。"
                return
            }
            let (newStart, overflow) = start.addingReportingOverflow(minutes * 60)
            guard !overflow else {
                notice = "入力した時刻が範囲外です。"
                return
            }
            do {
                let selection = ClockInSummarySelection(unit: unit, timeZoneID: TimeZone.current.identifier)
                proposal = try model.previewClockInCorrection(
                    day: day, oldStart: start, newStart: newStart, summary: selection, historical: historical
                )
            } catch {
                notice = "時刻・前勤務日・要確認記録・捕捉参考情報を確認してください。訂正案は未保存です。"
            }
        }

        private func confirm(_ value: WorktimeClockInProposal) {
            proposal = nil
            do {
                try model.confirmClockInCorrection(value)
                notice = "始業時刻を訂正しました。"
            } catch is ClockInInteractionError {
                notice = "訂正案が失効しました。最新記録から再確認してください。"
            } catch is CommittedCheckpointError {
                notice = "訂正は保存済みです。既存データを再読込してください。"
            } catch {
                notice = "確定結果を確認してください。再操作せず最新記録を読み込んでください。"
            }
        }

        private func worked(_ value: WorktimeGlance) -> String {
            ClockInCorrectionLabels.duration(value.snapshot.bounds.lower ... value.snapshot.bounds.upper)
        }
    }

    private struct ClockInSummaryImpactView: View {
        let impact: ClockInSummaryImpact

        var body: some View {
            let zone = impact.period.timeZoneID
            let first = ClockInCorrectionLabels.date(impact.period.start, zone: zone)
            let last = ClockInCorrectionLabels.date(impact.period.end - 1, zone: zone)
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text(first == last ? first : "\(first)〜\(last)").font(.headline)
                Text("終了済み：\(impact.before.endedDays) → \(impact.after.endedDays)件")
                comparison("実働", impact.before.worked, impact.after.worked)
                comparison("目標合計", impact.before.target ... impact.before.target,
                           impact.after.target ... impact.after.target)
                comparison("日次不足合計", impact.before.dailyShortfall, impact.after.dailyShortfall)
                comparison("日次超過合計", impact.before.dailySurplus, impact.after.dailySurplus)
            }
        }

        private func comparison(_ title: String, _ before: ClosedRange<Int64>, _ after: ClosedRange<Int64>) -> Text {
            Text("\(title)：\(ClockInCorrectionLabels.duration(before)) → \(ClockInCorrectionLabels.duration(after))")
        }
    }

    private enum ClockInCorrectionLabels {
        static func duration(_ range: ClosedRange<Int64>) -> String {
            range.lowerBound == range.upperBound ? "\(range.lowerBound)秒" : "\(range.lowerBound)〜\(range.upperBound)秒"
        }

        static func date(_ instant: Int64, zone: String) -> String {
            label(instant, zone: zone, includeTime: false)
        }

        static func time(_ instant: Int64, zone: String) -> String {
            label(instant, zone: zone, includeTime: true)
        }

        private static func label(_ instant: Int64, zone: String, includeTime: Bool) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: zone)
            formatter.dateStyle = .medium
            formatter.timeStyle = includeTime ? .medium : .none
            return formatter.string(from: Date(timeIntervalSince1970: Double(instant)))
        }
    }
#endif
