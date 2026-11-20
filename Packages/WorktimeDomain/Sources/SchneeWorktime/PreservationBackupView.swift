#if os(macOS)
    import SwiftUI

    @MainActor
    struct PreservationBackupView: View {
        @ObservedObject var model: DesktopModel

        var body: some View {
            DisclosureGroup("起動できない記録の保全") {
                Text("保存済み履歴のみの平文JSONです。観測情報の追記・退勤・復元は行いません。").font(.caption)
                Text("保存フォルダ外の所有者専用ローカルフォルダを選択してください。").font(.caption)
                Button("読取専用で履歴を保全") { model.choosePreservationDestination() }
                    .disabled(!model.canPreserveUnavailableDatabase)
                if let notice = model.backupNotice {
                    Text(notice).font(.caption).textSelection(.enabled)
                }
                Text("破損・未処理のSQLite補助ファイルがある場合は保全を拒否します。原本全体の保全を優先してください。")
                    .font(.caption)
            }
        }
    }
#endif
