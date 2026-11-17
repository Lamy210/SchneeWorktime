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

        var body: some View {
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
                    } else if case let .projected(earliest, departure) = countdown {
                        Text("最短目標達成まで：\(DepartureCountdown.duration(earliest))").font(.caption)
                        Text("休憩込み退勤見込み：\(DepartureCountdown.duration(departure))").font(.caption)
                    }
                    if glance.snapshot.bounds.lower != glance.snapshot.bounds.upper {
                        Text("要確認区間あり").foregroundStyle(.orange).font(.caption)
                    }
                } else {
                    Text(model.ready ? "勤務記録なし" : "記録を確認してください").font(.headline)
                }
                Text("予測は勤務実績ではありません。").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(16)
            .background(.regularMaterial)
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )) { _ in
                repairPlacement()
            }
        }

        private func rangeLabel(_ bounds: ClosedRange<Int64>) -> String {
            let lower = DepartureCountdown.duration(bounds.lowerBound)
            let upper = DepartureCountdown.duration(bounds.upperBound)
            return lower == upper ? lower : "\(lower)〜\(upper)"
        }
    }
#endif
