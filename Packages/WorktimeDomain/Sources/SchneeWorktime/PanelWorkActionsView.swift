#if os(macOS)
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct PanelWorkActionsView: View {
        @ObservedObject var model: DesktopModel
        @AppStorage("nextDayTargetMinutes") private var targetMinutes = 420
        @AppStorage("nextDayRestMinutes") private var restMinutes = 60
        @State private var pending: PanelActionContext?

        private var context: PanelActionContext {
            model.actionContext
        }

        private var instant: Int64 {
            model.glance?.observedAt ?? 0
        }

        private var profile: WorkdayProfile? {
            try? NextDaySettings(targetMinutes: targetMinutes, restMinutes: restMinutes).profile
        }

        var body: some View {
            let current = context
            let available = current.available(at: instant)
            VStack(alignment: .leading, spacing: 6) {
                if let pending, pending == current, available.contains(.clockOut) {
                    Text(pending.day?.state == .onBreak ? "休憩を終了して退勤しますか？" : "退勤を確定しますか？")
                        .font(.caption)
                    HStack {
                        Button("キャンセル") { self.pending = nil }
                        Button("退勤を確定") {
                            self.pending = nil
                            execute(.clockOut, expected: pending, confirmed: true)
                        }
                    }
                } else if !available.isEmpty {
                    Menu("勤務操作") {
                        ForEach(available, id: \.rawValue) { action in
                            Button(action.title) {
                                if action == .clockOut {
                                    guard context == current else { return }
                                    pending = current
                                } else {
                                    execute(action, expected: current)
                                }
                            }
                            .disabled(action == .start && profile == nil)
                        }
                    }
                } else if model.reviewProposal != nil {
                    Text("メニューバーで訂正案を確認してください。").font(.caption)
                }
            }
            .onChange(of: current) { _, _ in pending = nil }
        }

        private func execute(_ action: PanelWorkAction, expected: PanelActionContext, confirmed: Bool = false) {
            model.performAction(action, expected: expected, confirmed: confirmed, profile: profile)
        }
    }
#endif
