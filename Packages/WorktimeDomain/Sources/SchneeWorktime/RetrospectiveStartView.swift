#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct RetrospectiveStartView: View {
        @ObservedObject var model: DesktopModel
        let targetMinutes: Int
        let restMinutes: Int
        @State private var start = Date()
        @State private var proposal: RetrospectiveStartProposal?
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("過去の始業時刻を記録") {
                if let proposal {
                    Text("始業：\(label(proposal.startedAt))").font(.headline)
                    Text("確認時点の実働：\(DepartureCountdown.duration(proposal.preview.snapshot.bounds.lower))")
                        .font(.caption)
                    Text("始業から保存時点まで休憩・中断なしで勤務したことを確認してください。")
                        .font(.caption)
                    Button("勤務実績として確定") { confirm(proposal) }
                    Button("キャンセル") { self.proposal = nil }
                } else {
                    DatePicker("始業日時", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    Button("記録内容を確認") { prepare() }
                        .disabled(model.choosingBackupDestination)
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            .onChange(of: targetMinutes) { _, _ in proposal = nil }
            .onChange(of: restMinutes) { _, _ in proposal = nil }
        }

        private func prepare() {
            notice = nil
            proposal = nil
            guard let instant = Int64(exactly: start.timeIntervalSince1970.rounded(.down)) else {
                notice = "始業時刻を確認してください。"
                return
            }
            do {
                proposal = try model.previewRetrospectiveStart(
                    at: instant, targetMinutes: targetMinutes, restMinutes: restMinutes
                )
            } catch {
                notice = "過去の日時を指定し、勤務の重複や設定・時計を確認してください。"
            }
        }

        private func confirm(_ value: RetrospectiveStartProposal) {
            proposal = nil
            do {
                try model.confirmRetrospectiveStart(value)
            } catch is CommittedCheckpointError {
                notice = "操作は保存済みです。観測情報の保存に失敗したため再読込してください。"
            } catch {
                notice = "確定できませんでした。最新の勤務状態・保存結果を確認してください。"
            }
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.year().month().day().hour().minute())
        }
    }
#endif
