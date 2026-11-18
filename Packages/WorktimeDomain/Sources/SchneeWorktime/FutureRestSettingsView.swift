#if os(macOS)
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct FutureRestSettingsView: View {
        @ObservedObject var model: DesktopModel
        let day: Workday
        @State private var minutes = 30
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("当日の残り休憩予定") {
                Text("保存時点からの残り予定です。勤務・休憩の実績は変更しません。")
                    .font(.caption)
                Stepper("残り予定：\(minutes)分", value: $minutes, in: NextDaySettings.restRange)
                Button("残り休憩予定を保存") { save(minutes) }
                Button("標準休憩予定に戻す") { save(nil) }
                    .disabled(day.futureRestPlan == nil)
                if let notice {
                    Text(notice).font(.caption)
                }
            }
            .disabled(model.choosingBackupDestination || model.reviewProposal != nil)
            .onChange(of: day) { _, _ in
                minutes = 30
            }
        }

        private func save(_ value: Int?) {
            do {
                try model.setFutureRest(minutes: value, expectedDay: day)
                notice = "休憩予定を更新しました。"
            } catch is CommittedCheckpointError {
                notice = "操作は保存済みです。観測情報の保存に失敗したため再読込してください。"
            } catch {
                notice = "保存できませんでした。最新の勤務状態・時計・保存結果を確認してください。"
            }
        }
    }
#endif
