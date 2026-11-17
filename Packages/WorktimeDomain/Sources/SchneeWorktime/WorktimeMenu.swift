#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import WorktimeApplication
import WorktimeDomain

@MainActor
struct WorktimeMenu: View {
    @ObservedObject var model: DesktopModel
    @State private var confirmCreate = false
    @State private var confirmBreakExit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SchneeWorktime").font(.headline)
            Text("開発版 · 正式な勤怠記録ではありません")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let glance = model.glance {
                summary(glance)
                if model.ready {
                    actions(glance.day).disabled(model.reviewProposal != nil)
                    reviewSection(glance)
                }
            } else if model.ready {
                Text("勤務記録なし")
                Button("勤務開始") { model.start() }
            } else {
                Text(model.message ?? "記録を読み込めません")
                    .font(.caption)
                Button("既存データを再読込") { model.open(create: false) }
                Button("新規データベースを作成") { confirmCreate = true }
            }
            Divider()
            Button("アプリを終了") { NSApplication.shared.terminate(nil) }
        }
        .padding(16)
        .frame(width: 320)
        .confirmationDialog("勤務記録を新規作成しますか？", isPresented: $confirmCreate) {
            Button("新規作成") { model.open(create: true) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("以前の記録が見つからない場合は、新規作成せずバックアップを確認してください。")
        }
        .confirmationDialog("休憩を終了して退勤しますか？", isPresented: $confirmBreakExit) {
            Button("退勤を確定") { model.perform(.clockOut(confirmBreak: true)) }
            Button("キャンセル", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func summary(_ glance: WorktimeGlance) -> some View {
        Text(stateLabel(glance.day.state)).font(.headline)
        forecastLabel(glance.forecast.goal)
        Text("実働：\(duration(glance.snapshot.bounds.lower ... glance.snapshot.bounds.upper))")
        Text("目標まで：\(duration(glance.forecast.remaining, roundUp: true))")
        Text("日次目標超過：\(duration(glance.forecast.surplus))")
        Text("残り予定休憩：\(duration(glance.snapshot.remainingRest ... glance.snapshot.remainingRest, roundUp: true))")
            .font(.caption)
        if glance.snapshot.bounds.lower != glance.snapshot.bounds.upper {
            Text("要確認区間あり。実働は上下限を表示しています。")
                .foregroundStyle(.orange)
                .font(.caption)
        }
        if glance.day.state == .ended, let end = glance.day.intervals.last?.end {
            Text("退勤実績：\(timeLabel(end))")
        }
    }

    @ViewBuilder
    private func reviewSection(_ glance: WorktimeGlance) -> some View {
        if let notice = model.reviewNotice {
            Text(notice).font(.caption)
        }
        if let proposal = model.reviewProposal {
            Divider()
            Text("訂正案（未保存）").font(.headline)
            Text("\(reviewTimeLabel(proposal.selection.start))〜\(reviewTimeLabel(proposal.selection.end))")
                .font(.caption)
            Text("分類：\(classificationLabel(proposal.classification))")
            Text("試算時刻：\(reviewTimeLabel(proposal.observedAt))").font(.caption)
            Text("訂正前の実働：\(workedLabel(proposal.before))")
            Text("訂正後の実働：\(workedLabel(proposal.after))")
            Text("退勤見込み：\(goalLabel(proposal.before.forecast.goal)) → \(goalLabel(proposal.after.forecast.goal))")
                .font(.caption)
            HStack {
                Button("キャンセル") { model.cancelReview() }
                Button("訂正を保存") { model.acceptReview() }
            }
        } else if let gap = glance.reviewableGaps.first {
            Divider()
            Text("要確認区間（残り\(glance.reviewableGaps.count)件）").font(.headline)
            Text("\(reviewTimeLabel(gap.start))〜\(reviewTimeLabel(gap.end))").font(.caption)
            Text("区間全体を分類します。実態が混在する場合は保存しないでください（部分訂正UIは未実装）。")
                .font(.caption)
            Button("勤務継続として確認") { model.prepareReview(selection: gap, classification: .work) }
            Button("休憩として訂正") { model.prepareReview(selection: gap, classification: .rest) }
            Button("非勤務として訂正") { model.prepareReview(selection: gap, classification: .gap) }
        }
    }

    private func classificationLabel(_ classification: ReviewClassification) -> String {
        switch classification {
        case .work: "勤務"
        case .rest: "休憩"
        case .gap: "非勤務"
        }
    }

    private func workedLabel(_ glance: WorktimeGlance) -> String {
        let bounds = glance.snapshot.bounds
        return bounds.lower == bounds.upper ? "\(bounds.lower)秒" : "\(bounds.lower)〜\(bounds.upper)秒"
    }

    private func goalLabel(_ goal: GoalForecast) -> String {
        switch goal {
        case let .projected(_, departure): timeLabel(departure)
        case .reached: "目標達成"
        case .uncertain: "要確認"
        case .onBreak: "休憩中"
        case .ended: "退勤済み"
        }
    }

    @ViewBuilder
    private func forecastLabel(_ goal: GoalForecast) -> some View {
        switch goal {
        case let .projected(earliest, departure):
            Text("休憩込み退勤見込み（現在のタイムゾーン）").font(.caption)
            Text(timeLabel(departure)).font(.title2).monospacedDigit()
            Text("最短達成：\(timeLabel(earliest))").font(.subheadline)
        case .reached:
            Text("確認済み実働が目標に到達").font(.title3)
        case .uncertain:
            Text("退勤見込み未確定・要確認").font(.title3)
        case .onBreak:
            Text("休憩終了時刻が未確定").font(.title3)
        case .ended:
            Text("退勤済み・実績を表示").font(.title3)
        }
    }

    @ViewBuilder
    private func actions(_ day: Workday) -> some View {
        switch day.state {
        case .working:
            Button("休憩開始") { model.perform(.startBreak) }
            Button("退勤") { model.perform(.clockOut(confirmBreak: false)) }
        case .onBreak:
            Button("休憩終了") { model.perform(.endBreak) }
            Button("退勤") { confirmBreakExit = true }
        case .ended:
            Button("新しい勤務日を開始") { model.start() }
            Button("直前の勤務日を再開") { model.perform(.resume(id: day.id)) }
        }
    }

    private func stateLabel(_ state: WorkdayState) -> String {
        switch state {
        case .working: "勤務中"
        case .onBreak: "休憩中"
        case .ended: "退勤済み"
        }
    }

    private func reviewTimeLabel(_ instant: Int64) -> String {
        Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute().second())
    }

    private func timeLabel(_ instant: Int64) -> String {
        Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute())
    }

    private func duration(_ seconds: ClosedRange<Int64>, roundUp: Bool = false) -> String {
        func minutes(_ value: Int64) -> Int64 {
            value / 60 + (roundUp && value % 60 > 0 ? 1 : 0)
        }
        let lower = minutes(seconds.lowerBound)
        let upper = minutes(seconds.upperBound)
        return lower == upper ? "\(lower)分" : "\(lower)〜\(upper)分"
    }
}
#endif
