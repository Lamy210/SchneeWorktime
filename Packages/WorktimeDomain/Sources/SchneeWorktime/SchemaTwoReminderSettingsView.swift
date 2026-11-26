#if os(macOS)
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    /// Schema-2 uses the same owner-scoped OS reminder scheduler as schema-1,
    /// but its desired state is derived only from the committed schema-2 Journal.
    @MainActor
    struct SchemaTwoReminderSettingsView: View {
        @ObservedObject var model: DesktopModel

        var body: some View {
            DisclosureGroup("schema-2 · 勤務の通知") {
                Text("確定済み勤務記録と、時計・観測情報を確認できるときだけ予約します。通知は勤務実績ではありません。")
                    .font(.caption)
                if model.remindersSupported {
                    reminderControls
                } else {
                    Text("通知は署名済みかどうかにかかわらず、macOSの.app起動環境でのみ確認できます。")
                        .font(.caption)
                }
            }
        }

        private var reminderControls: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([ReminderLead.thirty, .fifteen, .five], id: \.rawValue) { lead in
                    Toggle("退勤見込みの\(lead.rawValue / 60)分前", isOn: Binding(
                        get: { model.departureLeads.contains(lead) },
                        set: { model.setDepartureLead(lead, enabled: $0) }
                    ))
                }
                Toggle("最短目標達成の15分前", isOn: Binding(
                    get: { model.earliestReminderEnabled },
                    set: { model.setEarliestReminder($0) }
                ))
                Text("参考終業時刻の新規捕捉・設定は未接続です。新たな参考時刻の通知は作成しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.remindersEnabled {
                    Button("通知を無効にする") { model.disableReminders() }
                    Button("macOSの通知許可を再確認") { model.enableReminders() }
                } else {
                    Button("通知を有効にする") { model.enableReminders() }
                }
                Text(model.reminderStatus.isEmpty ? "通知の状態を確認中" : model.reminderStatus)
                    .font(.caption)
                Text("睡眠・時刻ずれ・保存版の競合では予約を取消し、配信はmacOS側の許可と動作に依存します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.reminderEditingAllowed || model.requestingReminderPermission || model.reminderRunning)
        }
    }
#endif
