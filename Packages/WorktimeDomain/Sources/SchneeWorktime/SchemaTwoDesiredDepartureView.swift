#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    /// An intention only: never performs a clock-out or infers work from gaps.
    @MainActor
    struct SchemaTwoDesiredDepartureView: View {
        @ObservedObject var model: DesktopModel
        @State private var candidate = Date().addingTimeInterval(3600)
        @State private var proposal: JournalV2DesiredDepartureProposal?
        @State private var expected: JournalV2WorkActionContext?
        @State private var warningAcknowledged = false
        @State private var clearing: JournalV2WorkActionContext?
        @State private var confirmClear = false
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("希望退勤時刻（schema-2）") {
                Text("希望の日時を保存します。自動退勤・勤務実績の変更は行いません。")
                    .font(.caption)
                if let glance = model.schemaTwoWorkGlance, glance.day.state != .ended {
                    DesiredDepartureStatusView(glance: glance)
                    DatePicker(
                        "希望退勤日時", selection: $candidate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Button("希望時刻を確認") { preview() }
                    if let proposal {
                        confirmation(proposal)
                    }
                    if glance.desiredDepartureAt != nil {
                        Button("保存済みの希望を解除") { prepareClear() }
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            .disabled(!model.schemaTwoDesiredDepartureEnabled)
            .confirmationDialog("保存済みの希望退勤時刻を解除しますか？", isPresented: $confirmClear) {
                Button("希望退勤の設定を解除", role: .destructive) { clear() }
                Button("キャンセル", role: .cancel) { reset() }
            } message: {
                Text("勤務実績や退勤打刻は変更しません。希望に基づく通知も再計算します。")
            }
            .onChange(of: model.schemaTwoActionContext) { _, newValue in
                if let expected, newValue?.permitsRoutineObservation(since: expected) != true {
                    warningAcknowledged = false
                }
                if let clearing, newValue?.permitsRoutineObservation(since: clearing) != true {
                    reset()
                    notice = "記録が更新されたため解除を中止しました。もう一度確認してください。"
                }
            }
            .onChange(of: candidate) { _, _ in reset() }
        }

        private func confirmation(_ value: JournalV2DesiredDepartureProposal) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("保存候補：\(label(value.assessment.scenario.candidate))")
                Text(status(value.assessment)).font(.caption)
                if value.assessment.requiresWarning {
                    Toggle("見込みが不明・不整合でも希望として保存する", isOn: $warningAcknowledged)
                    Text("この条件では希望退勤を基準とする通知は予約されません。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let expected, model.schemaTwoActionContext?.permitsRoutineObservation(since: expected) != true {
                    Text("観測または記録が更新されました。入力日時は保持しています。")
                        .font(.caption).foregroundStyle(.orange)
                    Button("最新状態で希望時刻を再確認") { preview() }
                } else {
                    Button("確認した希望時刻を保存") { commit(value) }
                        .disabled(expected == nil || (value.assessment.requiresWarning && !warningAcknowledged))
                }
                Button("候補をキャンセル") { reset() }
            }
        }

        private func preview() {
            reset()
            notice = nil
            guard let expected = model.schemaTwoActionContext,
                  let instant = Int64(exactly: (candidate.timeIntervalSince1970 / 60).rounded(.down) * 60)
            else {
                notice = "勤務記録と希望日時を確認してください。"
                return
            }
            do {
                proposal = try model.previewSchemaTwoDesiredDeparture(at: instant, matching: expected)
                self.expected = expected
            } catch {
                notice = "希望日時または保存済み勤務状態を確認できません。再読込・再確認してください。"
            }
        }

        private func commit(_ value: JournalV2DesiredDepartureProposal) {
            guard let context = expected,
                  model.schemaTwoActionContext?.permitsRoutineObservation(since: context) == true,
                  Int64(exactly: (candidate.timeIntervalSince1970 / 60).rounded(.down) * 60) ==
                  value.assessment.scenario.candidate
            else {
                warningAcknowledged = false
                notice = "保存せず最新状態で再確認してください。"
                return
            }
            let approved = warningAcknowledged
            reset()
            do {
                try model.confirmSchemaTwoDesiredDeparture(
                    value, matching: context, warningAcknowledged: approved
                )
                notice = "希望退勤時刻を保存しました。通知は確定した記録から再計算します。"
            } catch DesiredDepartureSaveError.staleProposal {
                notice = "勤務予測または記録が変わりました。入力日時を保持しています。最新状態で再確認してください。"
            } catch {
                notice = "保存を確認できません。自動再試行せず、最新の記録を確認してください。"
            }
        }

        private func prepareClear() {
            reset()
            guard let context = model.schemaTwoActionContext else { return }
            clearing = context
            confirmClear = true
        }

        private func clear() {
            let context = clearing
            reset()
            guard let context else { return }
            do {
                try model.clearSchemaTwoDesiredDeparture(matching: context)
                notice = "保存済みの希望退勤時刻を解除しました。"
            } catch {
                notice = "解除を確認できません。自動再試行せず最新の記録を確認してください。"
            }
        }

        private func reset() {
            proposal = nil
            expected = nil
            warningAcknowledged = false
            clearing = nil
            confirmClear = false
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant))
                .formatted(.dateTime.year().month().day().hour().minute())
        }

        private func status(_ assessment: DesiredDepartureAssessment) -> String {
            switch assessment.status {
            case .feasible: "勤務予測上、実現可能な希望"
            case .infeasible: "休憩・勤務の予測と不整合（通知停止）"
            case .uncertain: "未観測区間等で見込みが不明（通知停止）"
            case .expired: "候補日時を過ぎています"
            case .ended: "退勤済みです"
            }
        }
    }
#endif
