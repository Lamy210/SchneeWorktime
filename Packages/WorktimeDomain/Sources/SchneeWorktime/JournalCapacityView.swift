#if os(macOS)
    import SwiftUI

    @MainActor
    struct JournalCapacityView: View {
        @ObservedObject var model: DesktopModel

        var body: some View {
            if let capacity = model.controller?.journalCapacity, capacity.shouldWarn {
                VStack(alignment: .leading, spacing: 4) {
                    Text("履歴保存の残り：\(capacity.remainingEvents)イベント")
                    if !capacity.canOpenWorkday {
                        Text("退勤用の余裕を確保するため、新規勤務・再開を停止しています。")
                    }
                    Text("履歴をバックアップしてください。上限到達前の移行が必要です。")
                    Text("残り件数は保存成功を保証しません。")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }
#endif
