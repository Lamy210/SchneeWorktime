#if os(macOS)
    import SwiftUI
    import WorktimeApplication

    @MainActor
    struct HistoryResetView: View {
        @ObservedObject var model: DesktopModel
        @State private var confirmation = ""

        var body: some View {
            DisclosureGroup("現在のDB内の勤務記録を削除") {
                Text("勤務履歴・訂正・観測情報を初期化します。外部に保存したJSON/CSVや別のコピーは削除しません。")
                    .font(.caption)
                Text("元に戻せません。ファイル上の痕跡の完全消去ではありません。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("削除内容を確認") {
                    confirmation = ""
                    model.prepareReset()
                }
                .disabled(!model.canPreviewReset)
                if let proposal = model.resetState.proposal {
                    Text("勤務日：\(proposal.workdays)件／訂正：\(proposal.corrections)件")
                    if proposal.hasActiveWorkday {
                        Text("現在の未終了勤務も削除対象です。").foregroundStyle(.orange)
                    }
                    Text("保存revision：\(proposal.version.revision)").font(.caption)
                    TextField("確認のため「削除」と入力", text: $confirmation)
                    Button("現在のDBを初期化", role: .destructive) {
                        model.confirmReset(version: proposal.version, confirmation: confirmation)
                        confirmation = ""
                    }
                    .disabled(confirmation != "削除" || !model.canConfirmReset)
                    Button("キャンセル") {
                        confirmation = ""
                        model.cancelReset()
                    }
                }
                if model.resetState.inProgress {
                    ProgressView("初期化処理中")
                }
                if let notice = model.resetState.notice {
                    Text(notice).font(.caption)
                }
            }
        }
    }
#endif
