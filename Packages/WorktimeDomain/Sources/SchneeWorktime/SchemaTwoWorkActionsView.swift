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
        @State private var pendingSettings: JournalV2ClockInSettings?
        @State private var pendingTargetMinutes: Int?
        @State private var pendingRestMinutes: Int?
        @State private var confirmationNotice: String?

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
                Text("勤務・休憩・希望退勤と、要確認区間の訂正に対応。過去日の未観測区間と限定復元に対応。全履歴消去は未対応です。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                statusSummary
                if let expected = model.schemaTwoActionContext {
                    actions(expected)
                }
                if let pending, let context {
                    confirmation(pending, expected: context)
                }
                if let confirmationNotice {
                    Text(confirmationNotice).font(.caption).foregroundStyle(.orange)
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
                if let glance = model.schemaTwoWorkGlance, !glance.reviewableGaps.isEmpty {
                    SchemaTwoReviewableGapsView(model: model, glance: glance)
                }
                restBoundaryControls
                SchemaTwoDesiredDepartureView(model: model)
                SchemaTwoHistoricalReviewView(model: model)
                SchemaTwoReminderSettingsView(model: model)
                SchemaTwoRollbackView(model: model)
                Button("観測を停止して履歴の読み取り専用表示に戻る") {
                    model.stopSchemaTwoObservation()
                }
                .disabled(model.schemaTwoWorkBusy)
                Text("観測停止は退勤打刻ではありません。再開時の未観測時間は要確認になります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.maintenanceInProgress)
            .onChange(of: targetMinutes) { _, _ in invalidateProfile() }
            .onChange(of: restMinutes) { _, _ in invalidateProfile() }
        }

        @ViewBuilder
        private var restBoundaryControls: some View {
            if let day = model.schemaTwoWorkGlance?.day {
                SchemaTwoRestBoundaryView(model: model, day: day, boundary: .start)
                SchemaTwoRestBoundaryView(model: model, day: day, boundary: .end)
            }
        }

        @ViewBuilder
        private var statusSummary: some View {
            if let glance = model.schemaTwoWorkGlance {
                Text(status(glance.day.state)).font(.headline)
                Text("実働：\(duration(glance.snapshot.bounds.lower ... glance.snapshot.bounds.upper))")
                    .font(.caption)
                ReferenceStatusView(glance: glance)
                if glance.snapshot.bounds.lower != glance.snapshot.bounds.upper {
                    Text("未観測時間があります。実働は範囲で表示し、勤務したと断定しません。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("未開始の勤務記録です。").font(.caption)
            }
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
                ReferenceSettingsView()
                    .disabled(pending != nil)
                Text("参考終業の設定は次の勤務開始時に固定されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("勤務開始") { prepare(.clockIn, context: expected) }
                    .disabled(!expected.canOpenWorkday || !validProfile)
                SchemaTwoRetrospectiveStartView(model: model, targetMinutes: targetMinutes, restMinutes: restMinutes)
            }
        }

        private func confirmation(_ action: Action, expected: JournalV2WorkActionContext) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("確認：\(actionLabel(action))").font(.headline)
                if let pendingSettings {
                    Text("勤務開始時の参考設定：\(referenceLabel(pendingSettings))").font(.caption)
                }
                Text("確定時の時刻を記録します。休憩中の退勤は休憩終了も伴います。")
                    .font(.caption)
                if model.schemaTwoActionContext?.permitsRoutineObservation(since: expected) != true {
                    Text("観測または記録が更新されました。まだ保存していません。")
                        .font(.caption).foregroundStyle(.orange)
                    Button("最新状態で操作を再選択") {
                        clearPending()
                        confirmationNotice = "最新の勤務状態から操作を選び直してください。"
                    }
                } else {
                    Button("この操作を保存") { commit() }
                        .disabled(model.schemaTwoWorkBusy || model.maintenanceInProgress ||
                            model.choosingBackupDestination)
                }
                Button("キャンセル") { clearPending() }
            }
        }

        private func actionLabel(_ action: Action) -> String {
            switch action {
            case .clockIn: "勤務開始"
            case .startBreak: "休憩開始"
            case .endBreak: "休憩終了"
            case .clockOut: "退勤"
            }
        }

        private func invalidateProfile() {
            guard pending == .clockIn else { return }
            clearPending()
            confirmationNotice = "勤務開始設定が変わりました。最新の設定で再確認してください。"
        }

        private func prepare(_ action: Action, context: JournalV2WorkActionContext) {
            clearPending()
            if case .clockIn = action {
                do {
                    let settings = try NextDaySettings(targetMinutes: targetMinutes, restMinutes: restMinutes)
                    pendingSettings = try model.schemaTwoClockInSettings(profile: settings.profile)
                } catch {
                    confirmationNotice = "勤務開始・参考終業の設定を確認してください。"
                    return
                }
                pendingTargetMinutes = targetMinutes
                pendingRestMinutes = restMinutes
            }
            pending = action
            self.context = context
            confirmationNotice = nil
        }

        private func clearPending() {
            pending = nil
            context = nil
            pendingSettings = nil
            pendingTargetMinutes = nil
            pendingRestMinutes = nil
            confirmationNotice = nil
        }

        private func commit() {
            guard let pending, let expected = context,
                  model.schemaTwoActionContext?.permitsRoutineObservation(since: expected) == true
            else {
                confirmationNotice = "記録が更新されました。保存せず再確認してください。"
                return
            }
            defer { clearPending() }
            let command: WorkdayCommand
            switch pending {
            case .clockIn:
                guard validProfile, pendingTargetMinutes == targetMinutes,
                      pendingRestMinutes == restMinutes, let pendingSettings
                else {
                    model.schemaTwoWorkNotice = "勤務開始設定が変更されたため、内容を再確認してください。"
                    return
                }
                command = .clockIn(id: UUID(), profile: pendingSettings.profile)
            case .startBreak:
                command = .startBreak
            case .endBreak:
                command = .endBreak
            case .clockOut:
                command = .clockOut(confirmBreak: expected.day?.state == .onBreak)
            }
            model.performSchemaTwoWork(command, matching: expected, clockInSettings: pendingSettings)
        }

        private func referenceLabel(_ settings: JournalV2ClockInSettings) -> String {
            guard let time = settings.wallTime else { return "無効・\(settings.timeZoneID)" }
            let day = time.dayOffset == 0 ? "開始日" : "翌日"
            let clock = String(format: "%02d:%02d", time.hour, time.minute)
            let occurrence = switch time.repeatedTime {
            case .earlier: "早い方"
            case .later: "遅い方"
            case nil: "未選択"
            }
            return "\(day) \(clock)・\(settings.timeZoneID)（重複時刻：\(occurrence)）"
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
