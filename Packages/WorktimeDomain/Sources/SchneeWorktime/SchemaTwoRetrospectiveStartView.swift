#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct SchemaTwoRetrospectiveStartView: View {
        @ObservedObject var model: DesktopModel
        let targetMinutes: Int
        let restMinutes: Int
        @State private var start = Date()
        @State private var proposal: RetrospectiveStartProposal?
        @State private var expected: JournalV2WorkActionContext?
        @State private var notice: String?

        private var profile: WorkdayProfile? {
            try? NextDaySettings(targetMinutes: targetMinutes, restMinutes: restMinutes).profile
        }

        private var selectedInstant: Int64? {
            Int64(exactly: (start.timeIntervalSince1970 / 60).rounded(.down) * 60)
        }

        var body: some View {
            DisclosureGroup("過去の始業時刻を記録（schema-2）") {
                DatePicker("始業日時", selection: $start, displayedComponents: [.date, .hourAndMinute])
                Text("過去の勤務は観測事実ではなく、利用者による明示的な申告です。")
                    .font(.caption)
                Button("記録内容を確認") { prepare() }
                    .disabled(!model.schemaTwoRetrospectiveStartEnabled || profile == nil)
                if let proposal {
                    confirmation(proposal)
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            .onChange(of: start) { _, _ in reset() }
            .onChange(of: targetMinutes) { _, _ in reset() }
            .onChange(of: restMinutes) { _, _ in reset() }
            .onChange(of: model.schemaTwoActionContext) { _, newer in
                if let expected, expected != newer {
                    reset()
                    notice = "勤務状態が更新されました。入力日時を再確認してください。"
                }
            }
        }

        private func confirmation(_ value: RetrospectiveStartProposal) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("始業：\(label(value.startedAt))").font(.headline)
                Text("確認時点の実働：\(DepartureCountdown.duration(value.preview.snapshot.bounds.lower))")
                    .font(.caption)
                Text("始業から保存時点まで休憩・中断なしで勤務した場合にだけ確定してください。")
                    .font(.caption)
                Button("申告した勤務実績を確定") { commit(value) }
                    .disabled(!model.schemaTwoRetrospectiveStartEnabled ||
                        expected != model.schemaTwoActionContext || profile != value.preview.day.profile ||
                        selectedInstant != value.startedAt)
                Button("候補をキャンセル") { reset() }
            }
        }

        private func prepare() {
            reset()
            guard let context = model.schemaTwoActionContext, let profile,
                  let instant = selectedInstant
            else {
                notice = "日時と勤務開始設定を確認してください。"
                return
            }
            do {
                proposal = try model.previewSchemaTwoRetrospectiveStart(
                    at: instant, profile: profile, matching: context
                )
                expected = context
            } catch RetrospectiveStartError.futureStart {
                notice = "未来の始業は勤務実績として保存できません。予定として管理し、実際の始業後に打刻してください（始業予定の保存機能は未接続です）。"
            } catch RetrospectiveStartError.currentStart {
                notice = "現在の始業は「勤務開始」から記録してください。"
            } catch {
                notice = "過去日時・重複・容量・時計を確認してください。"
            }
        }

        private func commit(_ value: RetrospectiveStartProposal) {
            guard let context = expected, let profile,
                  context == model.schemaTwoActionContext, selectedInstant == value.startedAt,
                  profile == value.preview.day.profile
            else {
                reset()
                notice = "記録が更新されました。保存せず再確認してください。"
                return
            }
            reset()
            do {
                try model.commitSchemaTwoRetrospectiveStart(value, profile: profile, matching: context)
            } catch {
                notice = "保存を確認できません。自動再試行せず記録を確認してください。"
            }
        }

        private func reset() {
            proposal = nil
            expected = nil
            notice = nil
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant))
                .formatted(.dateTime.year().month().day().hour().minute())
        }
    }
#endif
