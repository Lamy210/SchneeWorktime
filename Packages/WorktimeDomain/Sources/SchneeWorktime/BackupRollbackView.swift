#if os(macOS)
    import SwiftUI
    import WorktimeApplication

    @MainActor
    struct BackupRollbackView: View {
        @ObservedObject var model: DesktopModel
        @State private var acknowledged = false

        var body: some View {
            DisclosureGroup("以前の勤務履歴へ復元") {
                Text("正常な記録の以前の履歴に戻します。同一世代の終了済みバックアップだけ使用できます。")
                    .font(.caption)
                Button("復元候補を選択") {
                    acknowledged = false
                    model.chooseRollbackSource()
                }
                .disabled(!model.canPreviewRollback)
                if let proposal = model.rollbackProposal {
                    Text("勤務日：\(proposal.currentDays)件 → \(proposal.restoredDays)件")
                    Text("保存revision：\(proposal.currentRevision) → \(proposal.sourceRevision)")
                    Text("後続の勤務・訂正履歴が取り除かれます。先に現在の記録を別ファイルに保全します。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Toggle("履歴が戻ることと保全ファイルの必要性を確認した", isOn: $acknowledged)
                    Button("保全先を選択して復元", role: .destructive) {
                        acknowledged = false
                        model.confirmRollback()
                    }
                    .disabled(!acknowledged || !model.canConfirmRollback)
                    Button("キャンセル") {
                        acknowledged = false
                        model.cancelRollback()
                    }
                    .disabled(model.choosingBackupDestination || model.maintenanceInProgress)
                }
                if model.maintenanceInProgress, !model.resetState.inProgress {
                    ProgressView("復元処理中")
                }
                if let notice = model.rollbackNotice {
                    Text(notice).font(.caption).textSelection(.enabled)
                }
                Text("別のDB、破損したDB、未終了の勤務、別世代への復元には対応しません。")
                    .font(.caption)
            }
        }
    }
#endif
