#if os(macOS)
    import SwiftUI
    import WorktimeApplication

    @MainActor
    struct SchemaTwoDatabaseResetView: View {
        @ObservedObject var model: DesktopModel
        @State private var confirmation: JournalV2ConfirmedReset?
        @State private var consent = ""
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("現在のDB内の勤務記録を削除（schema-2）") {
                Text("勤務履歴・訂正・観測情報を論理削除し、新しい保存世代に切り替えます。元に戻せません。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("外部JSON/CSV、別のコピー、設定、管理対象未確定のファイルは削除しません。物理消去ではありません。")
                    .font(.caption)
                Button("削除対象を確認") { prepare() }
                    .disabled(!model.canPreviewSchemaTwoReset)
                if let confirmation {
                    confirmationView(confirmation)
                }
                if model.maintenanceInProgress {
                    ProgressView("履歴の保守処理中")
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            .onChange(of: model.schemaTwoActionContext) { _, _ in
                if confirmation != nil {
                    clear()
                    notice = "記録が更新されました。削除対象を再確認してください。"
                }
            }
        }

        private func confirmationView(_ value: JournalV2ConfirmedReset) -> some View {
            let preview = value.preview
            return VStack(alignment: .leading, spacing: 5) {
                Text("勤務日：\(preview.workdays)件／訂正：\(preview.corrections)件")
                Text("revision：\(preview.version.revision)")
                if preview.hasActiveWorkday {
                    Text("現在の未終了勤務も削除されます。").foregroundStyle(.orange)
                }
                Text("削除後は旧世代バックアップを限定復元できません。")
                TextField("確認のため「削除」と入力", text: $consent)
                Button("現在のDBを初期化", role: .destructive) {
                    model.confirmSchemaTwoReset(value, consent: consent)
                    clear()
                }
                .disabled(consent != "削除" || !model.canConfirmSchemaTwoReset(value))
                Button("キャンセル") { clear() }
                    .disabled(model.maintenanceInProgress)
            }
            .font(.caption)
        }

        private func prepare() {
            clear()
            notice = nil
            do {
                confirmation = try model.previewSchemaTwoReset()
            } catch {
                notice = "削除対象を確認できません。最新記録を再読込してください。"
            }
        }

        private func clear() {
            confirmation = nil
            consent = ""
        }
    }
#endif
