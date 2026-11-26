#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct SchemaTwoWorkActionsView: View {
        @ObservedObject var model: DesktopModel
        @AppStorage("nextDayTargetMinutes") private var targetMinutes = 420
        @AppStorage("nextDayRestMinutes") private var restMinutes = 60
        @State private var pending: Action?
        @State private var context: JournalV2WorkActionContext?
        @State private var pendingProfile: WorkdayProfile?
        @State private var pendingTargetMinutes: Int?
        @State private var pendingRestMinutes: Int?
        @State private var confirming = false

        private enum Action {
            case clockIn, startBreak, endBreak, clockOut
        }

        private var validProfile: Bool {
            NextDaySettings.targetRange.contains(targetMinutes) &&
                NextDaySettings.restRange.contains(restMinutes)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label("schema-2 · 勤務記録", systemImage: "clock.badge.checkmark")
                    .font(.headline)
                Text("勤務開始・休憩・退勤のみ使用できます。訂正・通知・復元・全履歴削除は未接続です。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let glance = model.schemaTwoWorkGlance {
                    Text(status(glance.day.state)).font(.headline)
                    Text("実働：\(duration(glance.snapshot.bounds.lower ... glance.snapshot.bounds.upper))")
                        .font(.caption)
                    if glance.snapshot.bounds.lower != glance.snapshot.bounds.upper {
                        Text("未観測時間があります。実働は範囲で表示し、勤務したと断定しません。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("未開始の勤務記録です。").font(.caption)
                }
                if let expected = model.schemaTwoActionContext {
                    actions(expected)
                }
                if let notice = model.schemaTwoWorkNotice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                Button("schema-2全履歴をJSONでバックアップ") {
                    model.chooseSchemaTwoBackupDestination()
                }
                .disabled(model.choosingBackupDestination || model.schemaTwoWorkBusy)
                if let backupNotice = model.backupNotice {
                    Text(backupNotice).font(.caption).textSelection(.enabled)
                }
                SchemaTwoReminderSettingsView(model: model)
                Button("観測を停止して履歴の読み取り専用表示に戻る") {
                    model.stopSchemaTwoObservation()
                }
                .disabled(model.schemaTwoWorkBusy)
                Text("観測停止は退勤打刻ではありません。再開時の未観測時間は要確認になります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog("勤務記録を確定しますか？", isPresented: $confirming) {
                Button("この操作を保存") { commit() }
                Button("キャンセル", role: .cancel) { clearPending() }
            } message: {
                Text("現在の保存済み勤務状態と確認時の時刻を再検証してから記録します。休憩中の退勤は休憩終了も伴います。")
            }
            .onChange(of: model.schemaTwoActionContext) { _, newer in
                if newer != context {
                    clearPending()
                }
            }
            .onChange(of: targetMinutes) { _, _ in clearPending() }
            .onChange(of: restMinutes) { _, _ in clearPending() }
        }

        @ViewBuilder
        private func actions(_ expected: JournalV2WorkActionContext) -> some View {
            if let day = expected.day, day.state != .ended {
                switch day.state {
                case .working:
                    Button("休憩開始") { prepare(.startBreak, context: expected) }
                        .disabled(!expected.canAppend)
                    Button("退勤") { prepare(.clockOut, context: expected) }
                        .disabled(!expected.canAppend)
                case .onBreak:
                    Button("休憩終了") { prepare(.endBreak, context: expected) }
                        .disabled(!expected.canAppend)
                    Button("休憩を終了して退勤") { prepare(.clockOut, context: expected) }
                        .disabled(!expected.canAppend)
                case .ended:
                    EmptyView()
                }
            } else {
                Text("目標：\(targetMinutes)分／標準休憩：\(restMinutes)分")
                    .font(.caption)
                Text("参考時刻の自動保存は未接続です。目標と標準休憩のみ使用します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("勤務開始") { prepare(.clockIn, context: expected) }
                    .disabled(!expected.canOpenWorkday || !validProfile)
            }
        }

        private func prepare(_ action: Action, context: JournalV2WorkActionContext) {
            if case .clockIn = action {
                guard validProfile,
                      let profile = try? WorkdayProfile(
                          target: Int64(targetMinutes) * 60,
                          expectedRest: Int64(restMinutes) * 60
                      )
                else { return }
                pendingProfile = profile
                pendingTargetMinutes = targetMinutes
                pendingRestMinutes = restMinutes
            }
            pending = action
            self.context = context
            confirming = true
        }

        private func clearPending() {
            pending = nil
            context = nil
            pendingProfile = nil
            pendingTargetMinutes = nil
            pendingRestMinutes = nil
            confirming = false
        }

        private func commit() {
            guard let pending, let expected = context else {
                clearPending()
                return
            }
            defer { clearPending() }
            let command: WorkdayCommand
            switch pending {
            case .clockIn:
                guard validProfile, pendingTargetMinutes == targetMinutes,
                      pendingRestMinutes == restMinutes, let profile = pendingProfile
                else {
                    model.schemaTwoWorkNotice = "勤務開始設定が変更されたため、内容を再確認してください。"
                    return
                }
                command = .clockIn(id: UUID(), profile: profile)
            case .startBreak:
                command = .startBreak
            case .endBreak:
                command = .endBreak
            case .clockOut:
                command = .clockOut(confirmBreak: expected.day?.state == .onBreak)
            }
            model.performSchemaTwoWork(command, matching: expected)
        }

        private func status(_ state: WorkdayState) -> String {
            switch state {
            case .working: "勤務中"
            case .onBreak: "休憩中"
            case .ended: "退勤済み"
            }
        }

        private func duration(_ value: ClosedRange<Int64>) -> String {
            let lower = DepartureCountdown.duration(value.lowerBound)
            let upper = DepartureCountdown.duration(value.upperBound)
            return lower == upper ? lower : "\(lower)〜\(upper)"
        }
    }
#endif
