#if os(macOS)
    import AppKit
    import Combine
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct WorktimePanelView: View {
        @ObservedObject var model: DesktopModel
        let repairPlacement: () -> Void
        @AppStorage("worktimePanelDisplayMode") private var storedMode = PanelDisplayMode.detailed.rawValue

        private var mode: PanelDisplayMode {
            PanelDisplayMode(storedValue: storedMode)
        }

        var body: some View {
            ScrollView {
                panelContents
            }
            .background(.regularMaterial)
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )) { _ in
                repairPlacement()
            }
        }

        private var panelContents: some View {
            VStack(alignment: .leading, spacing: 8) {
                if model.ready, let glance = model.glance {
                    let countdown = DepartureCountdown(goal: glance.forecast.goal, observedAt: glance.observedAt)
                    Text(countdown.menuTitle)
                        .font(.title2.monospacedDigit())
                    Text("実働：\(rangeLabel(glance.snapshot.bounds.lower ... glance.snapshot.bounds.upper))")
                        .font(.headline)
                    Text("残り実働：\(rangeLabel(glance.forecast.remaining))")
                        .font(.caption)
                    if glance.day.state == .ended, let end = glance.day.intervals.last?.end {
                        let time = Date(timeIntervalSince1970: Double(end)).formatted(.dateTime.hour().minute())
                        Text("退勤実績：\(time)").font(.caption)
                    }
                    if mode == .detailed {
                        detailedForecast(glance)
                    }
                    if glance.snapshot.bounds.lower != glance.snapshot.bounds.upper {
                        Text("要確認区間あり").foregroundStyle(.orange).font(.caption)
                    }
                } else {
                    Text(model.ready ? "勤務記録なし" : "記録を確認してください").font(.headline)
                }
                PanelWorkActionsView(model: model)
                Text("予測は勤務実績ではありません。").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(16)
        }

        @ViewBuilder
        private func detailedForecast(_ glance: WorktimeGlance) -> some View {
            DesiredDepartureStatusView(glance: glance)
            ReferenceStatusView(glance: glance)
            Text("実働目標：\(DepartureCountdown.duration(glance.day.profile.target))").font(.caption)
            Text("残り予定休憩：\(DepartureCountdown.duration(glance.snapshot.remainingRest))").font(.caption)
            Text("日次目標超過：\(rangeLabel(glance.forecast.surplus))").font(.caption)
            if case let .projected(earliest, departure) = glance.forecast.goal {
                Text("退勤見込み：\(timeLabel(departure))").font(.headline)
                Text("最短目標達成：\(timeLabel(earliest))").font(.caption)
            }
        }

        private func timeLabel(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute())
        }

        private func rangeLabel(_ bounds: ClosedRange<Int64>) -> String {
            let lower = DepartureCountdown.duration(bounds.lowerBound)
            let upper = DepartureCountdown.duration(bounds.upperBound)
            return lower == upper ? lower : "\(lower)〜\(upper)"
        }
    }
#endif
