#if os(macOS)
    import SwiftUI
    import WorktimeApplication

    @MainActor
    struct SchemaTwoManagedHistoryPreviewView: View {
        @ObservedObject var model: DesktopModel
        @State private var preview: JournalV2ManagedHistoryPreview?
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("全履歴消去の対象確認（開発中・読取り専用）") {
                Text("現在のDBと明示登録済みの管理ファイルを確認します。削除は実行しません。")
                    .font(.caption)
                Button("対象を確認") { prepare() }
                    .disabled(!model.canPreviewSchemaTwoReset)
                if let preview {
                    scopeDetails(preview)
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                Text("外部JSON/CSV、別のコピー、旧復旧候補、設定はこの管理対象に含みません。")
                    .font(.caption)
                Text("全履歴消去の実行・復旧はまだ利用できません。物理消去の保証もありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: model.schemaTwoActionContext) { _, _ in
                if preview != nil {
                    preview = nil
                    notice = "勤務記録が更新されました。対象を再確認してください。"
                }
            }
        }

        private func scopeDetails(_ value: JournalV2ManagedHistoryPreview) -> some View {
            let scope = value.scope
            return VStack(alignment: .leading, spacing: 4) {
                Text("勤務日：\(scope.workdays)件／訂正：\(scope.corrections)件")
                Text("revision：\(scope.version.revision)")
                if scope.hasActiveWorkday {
                    Text("現在の未終了勤務も対象です。").foregroundStyle(.orange)
                }
                switch scope.state {
                case .notInitialized:
                    Text("管理台帳は未初期化です。管理対象がないと断定できません。")
                case .pendingErasure:
                    Text("未完了の消去があります。新しい消去を開始できません。")
                case .inventoried, .inconsistent:
                    counts(value)
                }
            }
            .font(.caption)
        }

        private func counts(_ value: JournalV2ManagedHistoryPreview) -> some View {
            let scope = value.scope
            return VStack(alignment: .leading, spacing: 3) {
                Text("登録：バックアップ \(scope.registeredBackups)件／診断 \(scope.registeredDiagnostics)件")
                Text("一致 \(scope.verifiedFiles)件／欠落 \(scope.missingFiles)件／変更 \(scope.changedFiles)件")
                Text("危険 \(scope.unsafeFiles)件／未登録 \(scope.unregisteredFiles)件")
                if scope.state == .inconsistent {
                    Text("管理状態に不一致があります。消去を開始できません。").foregroundStyle(.orange)
                } else {
                    Text("登録済み対象との照合結果に不一致はありません。")
                }
            }
        }

        private func prepare() {
            preview = nil
            notice = nil
            guard model.canPreviewSchemaTwoReset, let current = model.schemaTwoWorkSession else { return }
            do {
                preview = try current.previewManagedHistory(sample: DesktopModel.sample())
            } catch {
                notice = "管理台帳または記録を検証できません。ファイルを変更せず再確認してください。"
            }
        }
    }
#endif
