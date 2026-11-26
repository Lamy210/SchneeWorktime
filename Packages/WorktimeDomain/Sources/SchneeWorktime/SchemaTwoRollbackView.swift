#if os(macOS)
    import SwiftUI
    import WorktimeApplication

    @MainActor
    struct SchemaTwoRollbackView: View {
        @ObservedObject var model: DesktopModel
        @State private var acknowledged = false

        var body: some View {
            DisclosureGroup("以前の勤務履歴へ復元（schema-2）") {
                Text("正常な同一世代の以前の終了済み履歴だけ使用できます。")
                    .font(.caption)
                Button("復元候補を選択") {
                    acknowledged = false
                    model.chooseSchemaTwoRollback()
                }
                .disabled(!model.canChooseSchemaTwoRollback)
                if let confirmation = model.schemaTwoRollback {
                    confirmationView(confirmation)
                }
                if model.maintenanceInProgress {
                    ProgressView("保全・復元処理中")
                }
                Text("破損DB・別世代・勤務中の復元には対応しません。保全ファイルは平文です。")
                    .font(.caption)
            }
            .onChange(of: model.schemaTwoActionContext) { _, _ in acknowledged = false }
        }

        private func confirmationView(_ confirmation: JournalV2ConfirmedRollback) -> some View {
            let proposal = confirmation.proposal
            return VStack(alignment: .leading, spacing: 5) {
                Text("勤務日：\(proposal.currentDays)件 → \(proposal.restoredDays)件")
                Text("revision：\(proposal.currentVersion.revision) → \(proposal.sourceVersion.revision)")
                Text("後続の勤務・訂正が取り除かれ、新しい世代に切り替わります。現履歴は先に別ファイルへ保全します。")
                    .foregroundStyle(.orange)
                Toggle("復元対象と保全の必要性を確認した", isOn: $acknowledged)
                Button("保全先を選択して復元", role: .destructive) {
                    model.confirmSchemaTwoRollback(confirmation.context, acknowledged: acknowledged)
                    acknowledged = false
                }
                .disabled(!acknowledged || !model.canConfirmSchemaTwoRollback)
                Button("キャンセル") {
                    acknowledged = false
                    model.cancelSchemaTwoRollback()
                }
                .disabled(model.maintenanceInProgress || model.choosingBackupDestination)
            }
            .font(.caption)
        }
    }
#endif
