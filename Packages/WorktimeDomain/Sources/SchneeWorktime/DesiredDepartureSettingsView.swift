#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct DesiredDepartureStatusView: View {
        let glance: WorktimeGlance

        var body: some View {
            if let candidate = glance.desiredDepartureAt {
                Text("希望退勤：\(desiredDepartureLabel(candidate))")
                    .font(.headline)
                if let assessment = try? glance.assessDesiredDeparture(at: candidate) {
                    Text(statusLabel(assessment))
                        .font(.caption)
                } else {
                    Text("希望退勤の条件を確認してください。").font(.caption)
                }
            }
        }
    }

    @MainActor
    struct DesiredDepartureSettingsView: View {
        @ObservedObject var model: DesktopModel
        let day: Workday
        @State private var candidate = Date().addingTimeInterval(3600)
        @State private var proposal: DesiredDepartureProposal?
        @State private var acknowledged = false
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("希望退勤を保存") {
                Text("実際の退勤や勤務履歴を変更しません。希望は自動見込みと別に保存します。")
                    .font(.caption)
                DatePicker("希望退勤日時", selection: $candidate, displayedComponents: [.date, .hourAndMinute])
                Button("保存内容を確認") { preview() }
                if let proposal {
                    confirmation(proposal)
                }
                Button("保存済みの希望を解除") { clear() }
                    .disabled(model.glance?.desiredDepartureAt == nil)
                if let notice {
                    Text(notice).font(.caption)
                }
            }
            .disabled(!model.ready || model.choosingBackupDestination || model.reviewProposal != nil)
            .onChange(of: day) { _, _ in reset() }
            .onChange(of: candidate) { _, _ in reset() }
        }

        private func confirmation(_ value: DesiredDepartureProposal) -> some View {
            VStack(alignment: .leading) {
                Text("希望：\(desiredDepartureLabel(value.assessment.scenario.candidate))")
                Text(statusLabel(value.assessment)).font(.caption)
                if value.assessment.requiresWarning {
                    Toggle("条件が不明・不整合でも希望として保存する", isOn: $acknowledged)
                }
                Button("希望を確定") { confirm(value) }
                    .disabled(value.assessment.requiresWarning && !acknowledged)
                Button("キャンセル") { reset() }
            }
        }

        private func preview() {
            reset()
            guard let instant = Int64(exactly: (candidate.timeIntervalSince1970 / 60).rounded(.down) * 60) else {
                notice = "希望時刻を確認してください。"
                return
            }
            do {
                proposal = try model.previewDesiredDeparture(at: instant)
            } catch {
                notice = "未来の時刻と現在の勤務状態を確認してください。"
            }
        }

        private func confirm(_ value: DesiredDepartureProposal) {
            let warning = acknowledged
            reset()
            do {
                try model.confirmDesiredDeparture(value, warningAcknowledged: warning)
                notice = "希望退勤を保存しました。"
            } catch is CommittedCheckpointError {
                notice = "操作は保存済みです。観測情報の保存に失敗したため再読込してください。"
            } catch {
                notice = "保存できませんでした。最新の条件で再確認してください。"
            }
        }

        private func clear() {
            reset()
            do {
                try model.clearDesiredDeparture(expectedDay: day)
                notice = "希望退勤を解除しました。"
            } catch is CommittedCheckpointError {
                notice = "操作は保存済みです。観測情報の保存に失敗したため再読込してください。"
            } catch {
                notice = "解除できませんでした。最新の勤務状態を確認してください。"
            }
        }

        private func reset() {
            proposal = nil
            acknowledged = false
        }
    }

    private func desiredDepartureLabel(_ instant: Int64) -> String {
        Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute())
    }

    private func statusLabel(_ assessment: DesiredDepartureAssessment) -> String {
        switch assessment.status {
        case .feasible:
            if let remaining = assessment.scenario.remaining, remaining.upperBound > 0 {
                return "実現可能・目標まで\(DepartureCountdown.duration(remaining.upperBound))不足の見込み"
            }
            return "現在の条件で実現可能"
        case .infeasible: return "休憩予定と不整合・希望通知は停止"
        case .uncertain: return "条件が未確定・希望通知は停止"
        case .expired: return "経過済みの希望・自動退勤しません"
        case .ended: return "退勤済みの勤務日の希望"
        }
    }
#endif
