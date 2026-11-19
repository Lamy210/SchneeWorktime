#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct ClockOutCorrectionView: View {
        @ObservedObject var model: DesktopModel
        let day: Workday
        var historical: HistoricalReviewContext?
        @State private var offsetMinutes = "30"
        @State private var proposal: WorktimeClockOutProposal?
        @State private var notice: String?

        var body: some View {
            if day.state == .ended, let last = day.intervals.last, let end = last.end {
                if last.kind == .work {
                    DisclosureGroup("記録済み退勤時刻の訂正") {
                        editor(end)
                        if let proposal {
                            confirmation(proposal)
                        }
                        if let notice {
                            Text(notice).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .disabled(!model.ready || model.choosingBackupDestination || model.reviewProposal != nil)
                } else {
                    Text("休憩中に退勤した記録は退勤時刻訂正の対象外です。")
                        .font(.caption)
                }
            }
        }

        private func editor(_ end: Int64) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("元の退勤：\(label(end))")
                Text("現在のタイムゾーンで表示します。")
                    .font(.caption)
                TextField("変更分（分、前倒しは負数）", text: $offsetMinutes)
                Button("退勤訂正案を確認") { prepare(end) }
            }
            .onChange(of: offsetMinutes) { _, _ in proposal = nil }
        }

        private func confirmation(_ value: WorktimeClockOutProposal) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("退勤：\(label(value.oldEnd)) → \(label(value.newEnd))")
                Text("実働：\(worked(value.before)) → \(worked(value.after))")
                Text("日次不足：\(duration(value.before.forecast.remaining)) → \(duration(value.after.forecast.remaining))")
                Text("日次超過：\(duration(value.before.forecast.surplus)) → \(duration(value.after.forecast.surplus))")
                Text("変更する範囲の勤務実績が正しいことを確認してください。")
                Button("退勤訂正を確定") { confirm(value) }
                    .disabled(model.controller?.isCurrent(value) != true)
                Button("キャンセル") { proposal = nil }
                if model.controller?.isCurrent(value) != true {
                    Text("保存版が変わりました。訂正案を再作成してください。")
                }
            }
            .font(.caption)
        }

        private func prepare(_ end: Int64) {
            proposal = nil
            notice = nil
            guard let minutes = Int64(offsetMinutes), minutes != 0, (-1440 ... 1440).contains(minutes) else {
                notice = "±1440分以内の0以外の整数を指定してください。"
                return
            }
            let (newEnd, overflow) = end.addingReportingOverflow(minutes * 60)
            guard !overflow else { return }
            do {
                proposal = try model.previewClockOutCorrection(
                    day: day, oldEnd: end, newEnd: newEnd, historical: historical
                )
            } catch {
                notice = "時刻・後続勤務日・要確認記録を確認してください。訂正案は保存されていません。"
            }
        }

        private func confirm(_ value: WorktimeClockOutProposal) {
            proposal = nil
            do {
                try model.confirmClockOutCorrection(value)
                notice = "退勤時刻を訂正しました。"
            } catch is CommittedCheckpointError {
                notice = "訂正は保存済みです。既存データを再読込してください。"
            } catch {
                notice = "確定結果を確認してください。再操作せず最新記録を読み込んでください。"
            }
        }

        private func worked(_ value: WorktimeGlance) -> String {
            duration(value.snapshot.bounds.lower ... value.snapshot.bounds.upper)
        }

        private func duration(_ range: ClosedRange<Int64>) -> String {
            range.lowerBound == range.upperBound ? "\(range.lowerBound)秒" : "\(range.lowerBound)〜\(range.upperBound)秒"
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant))
                .formatted(.dateTime.year().month().day().hour().minute().second())
        }
    }
#endif
