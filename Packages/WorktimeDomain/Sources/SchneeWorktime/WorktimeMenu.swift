#if os(macOS)
    import AppKit
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct WorktimeMenu: View {
        @ObservedObject var model: DesktopModel
        @State private var confirmCreate = false
        @State private var confirmSchemaTwoCreate = false
        @State private var confirmBreakExit = false
        @State private var pendingBreakExit: PanelActionContext?
        @AppStorage("nextDayTargetMinutes") private var targetMinutes = 420
        @AppStorage("nextDayRestMinutes") private var restMinutes = 60

        private var settingsValid: Bool {
            NextDaySettings.targetRange.contains(targetMinutes) && NextDaySettings.restRange.contains(restMinutes)
        }

        var body: some View {
            ScrollView {
                contents
                    .padding(16)
            }
            .frame(width: 360, height: 540)
            .confirmationDialog("schema-2勤務記録を新規作成しますか？", isPresented: $confirmSchemaTwoCreate) {
                Button("schema-2を新規作成") { model.activateSchemaTwoWorkSession(createNew: true) }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("既存DBは上書きせず、新しいschema-2だけ作成します。通知停止の確認後に書込みモードになります。")
            }
            .confirmationDialog("勤務記録を新規作成しますか？", isPresented: $confirmCreate) {
                Button("新規作成") { model.open(create: true) }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("以前の記録が見つからない場合は、新規作成せずバックアップを確認してください。")
            }
            .confirmationDialog(
                "休憩を終了して退勤しますか？", isPresented: $confirmBreakExit, presenting: pendingBreakExit
            ) { expected in
                Button("退勤を確定") {
                    pendingBreakExit = nil
                    model.performAction(.clockOut, expected: expected, confirmed: true)
                }
                Button("キャンセル", role: .cancel) { pendingBreakExit = nil }
            }
            .onChange(of: model.actionContext) { _, _ in
                pendingBreakExit = nil
                confirmBreakExit = false
            }
        }

        private var contents: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("SchneeWorktime").font(.headline)
                Text("開発版 · 正式な勤怠記録ではありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                currentWorkdayContent
                if let notice = model.schemaTwoResetNotice {
                    Text(notice).font(.caption)
                }
                readySettings
                if model.schemaTwoInspection == nil, model.schemaTwoWorkSession == nil {
                    backupInspectionSettings
                    BackupRollbackView(model: model)
                    HistoryResetView(model: model)
                }
                Divider()
                Button("アプリを終了") { NSApplication.shared.terminate(nil) }
                    .disabled(model.maintenanceInProgress)
            }
        }

        @ViewBuilder
        private var currentWorkdayContent: some View {
            if model.schemaTwoWorkSession != nil {
                SchemaTwoWorkActionsView(model: model)
            } else if let glance = model.glance {
                summary(glance)
                if model.ready {
                    actions(glance.day).disabled(model.reviewProposal != nil)
                    reviewSection(glance)
                    Group {
                        RestEndCorrectionView(model: model, day: glance.day, boundary: .start)
                        RestEndCorrectionView(model: model, day: glance.day)
                        ClockInCorrectionView(model: model, day: glance.day)
                        ClockOutCorrectionView(model: model, day: glance.day)
                    }
                    .id("\(glance.day.id)-\(glance.day.revision)")
                    .disabled(!model.allowsOptionalJournalMutation)
                    if glance.day.state != .ended, model.reviewProposal == nil {
                        FutureRestSettingsView(model: model, day: glance.day)
                            .id(glance.day.id)
                            .disabled(!model.allowsOptionalJournalMutation)
                        DesiredDepartureSettingsView(model: model, day: glance.day)
                            .id(glance.day.id)
                            .disabled(!model.allowsOptionalJournalMutation)
                        DepartureScenarioView(glance: glance)
                    }
                }
            } else if model.schemaTwoInspection != nil {
                SchemaTwoReadOnlyHistoryView(model: model)
            } else if model.ready {
                Text("勤務記録なし")
                let context = model.actionContext
                Button("勤務開始") { start(expected: context) }
                    .disabled(!settingsValid || !context.enabled || !context.canOpenWorkday)
            } else {
                unavailableContent
            }
        }

        @ViewBuilder
        private var readySettings: some View {
            if model.ready {
                JournalCapacityView(model: model)
                let canStart = model.glance == nil || model.glance?.day.state == .ended
                if settingsValid, model.actionContext.canOpenWorkday, canStart {
                    RetrospectiveStartView(model: model, targetMinutes: targetMinutes, restMinutes: restMinutes)
                }
                nextDaySettings
                reminderSettings
                backupSettings
                WorktimeHistoryView(model: model)
                WorktimeSummaryView(model: model)
            }
        }

        @ViewBuilder
        private var unavailableContent: some View {
            if model.maintenanceInProgress {
                Text("履歴の保守処理中は操作できません。").font(.caption)
            } else {
                Text(model.message ?? "記録を読み込めません")
                    .font(.caption)
                Text("以前の記録がある場合は新規作成せず、アプリ終了後に保存フォルダ全体を保全してください。")
                    .font(.caption)
                if model.sessionLock != nil {
                    PreservationBackupView(model: model)
                }
                Button("既存データを再読込") { model.open(create: false) }
                    .disabled(model.choosingBackupDestination)
                if model.schemaTwoCanCreate {
                    Button("schema-2勤務記録を新規作成") { confirmSchemaTwoCreate = true }
                        .disabled(model.choosingBackupDestination || model.schemaTwoWorkBusy)
                }
                #if DEBUG
                    Button("開発用schema-1データベースを新規作成") { confirmCreate = true }
                        .disabled(model.choosingBackupDestination || model.schemaTwoWorkBusy)
                #endif
                if let notice = model.schemaTwoWorkNotice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
        }

        private var backupSettings: some View {
            DisclosureGroup("勤務履歴のバックアップ") {
                Text("保存済みの勤務履歴と訂正履歴を平文JSONとして保存します。未保存の訂正案や設定は含みません。")
                    .font(.caption)
                Text("所有者専用のローカルフォルダを指定してください。同期フォルダは避けてください。")
                    .font(.caption)
                Button("JSONバックアップの保存先を選択") { model.chooseBackupDestination() }
                    .disabled(model.choosingBackupDestination)
                Button("全履歴CSVの保存先を選択") { model.chooseBackupDestination(format: .csv) }
                    .disabled(model.choosingBackupDestination)
                Text("CSVはUTCのUnix秒で全勤務区間・要確認区間・訂正情報を出力します。復元にはJSONを使用します。")
                    .font(.caption)
                if let notice = model.backupNotice {
                    Text(notice)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }

        private var backupInspectionSettings: some View {
            DisclosureGroup("バックアップの内容を確認") {
                Text("既存の勤務記録を変更せずに、バックアップの構造と履歴を検証します。")
                    .font(.caption)
                Button("確認するファイルを選択") { model.chooseBackupForInspection() }
                    .disabled(model.choosingBackupDestination || model.maintenanceInProgress)
                if let inspection = model.backupInspection {
                    Text("勤務日：\(inspection.days)件")
                    Text("訂正履歴：\(inspection.corrections)件")
                    Text("保存revision：\(inspection.revision)")
                    if let first = inspection.firstStart, let last = inspection.lastStart {
                        Text("最初の勤務開始：\(reviewTimeLabel(first))").font(.caption)
                        Text("最後の勤務開始：\(reviewTimeLabel(last))").font(.caption)
                    }
                    if inspection.hasActiveDay {
                        Text("未終了勤務を含むため、限定ロールバックの対象にはできません。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let notice = model.inspectionNotice {
                    Text(notice).font(.caption)
                    Button("確認結果を閉じる") { model.clearBackupInspection() }
                }
                Text("この操作では復元・上書きは行いません。").font(.caption)
            }
        }

        private var nextDaySettings: some View {
            DisclosureGroup("次の勤務日の設定") {
                Text("現在と過去の勤務記録は変更しません。").font(.caption)
                if settingsValid {
                    Stepper("実働目標：\(targetMinutes)分", value: $targetMinutes,
                            in: NextDaySettings.targetRange, step: 5)
                    Stepper("標準休憩：\(restMinutes)分", value: $restMinutes,
                            in: NextDaySettings.restRange, step: 5)
                } else {
                    Text("設定値が無効です。既定値に戻してください。").font(.caption)
                }
                ReferenceSettingsView()
                Button("既定値（実働420分・休憩60分）に戻す") {
                    targetMinutes = 420
                    restMinutes = 60
                }
            }
        }

        private func start(expected: PanelActionContext) {
            let profile = try? NextDaySettings(targetMinutes: targetMinutes, restMinutes: restMinutes).profile
            model.performAction(.start, expected: expected, profile: profile)
        }

        @ViewBuilder
        private func summary(_ glance: WorktimeGlance) -> some View {
            Text(stateLabel(glance.day.state)).font(.headline)
            forecastLabel(glance.forecast.goal)
            DesiredDepartureStatusView(glance: glance)
            ReferenceStatusView(glance: glance)
            BreakRecordAdvisoryView(glance: glance)
            DepartureCountdownView(
                countdown: DepartureCountdown(goal: glance.forecast.goal, observedAt: glance.observedAt)
            )
            Text("実働目標：\(glance.day.profile.target / 60)分")
            Text("実働：\(duration(glance.snapshot.bounds.lower ... glance.snapshot.bounds.upper))")
            Text("目標まで：\(duration(glance.forecast.remaining, roundUp: true))")
            Text("日次目標超過：\(duration(glance.forecast.surplus))")
            Text("残り予定休憩：\(duration(glance.snapshot.remainingRest ... glance.snapshot.remainingRest, roundUp: true))")
                .font(.caption)
            if glance.snapshot.bounds.lower != glance.snapshot.bounds.upper {
                Text("要確認区間あり。実働は上下限を表示しています。")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if glance.day.state == .ended, let end = glance.day.intervals.last?.end {
                Text("退勤実績：\(timeLabel(end))")
            }
        }

        @ViewBuilder
        private func forecastLabel(_ goal: GoalForecast) -> some View {
            switch goal {
            case let .projected(earliest, departure):
                Text("休憩込み退勤見込み（現在のタイムゾーン）").font(.caption)
                Text(timeLabel(departure)).font(.title2).monospacedDigit()
                Text("最短達成：\(timeLabel(earliest))").font(.subheadline)
            case .reached:
                Text("確認済み実働が目標に到達").font(.title3)
            case .uncertain:
                Text("退勤見込み未確定・要確認").font(.title3)
            case .onBreak:
                Text("休憩終了時刻が未確定").font(.title3)
            case .ended:
                Text("退勤済み・実績を表示").font(.title3)
            }
        }

        @ViewBuilder
        private func actions(_ day: Workday) -> some View {
            let context = model.actionContext
            let available = context.available(at: model.glance?.observedAt ?? 0)
            switch day.state {
            case .working:
                Button("休憩開始") { model.performAction(.startBreak, expected: context) }
                    .disabled(!available.contains(.startBreak))
                Button("退勤") { model.performAction(.clockOut, expected: context, confirmed: true) }
                    .disabled(!available.contains(.clockOut))
            case .onBreak:
                Button("休憩終了") { model.performAction(.endBreak, expected: context) }
                    .disabled(!available.contains(.endBreak))
                Button("退勤") {
                    guard model.actionContext == context else { return }
                    pendingBreakExit = context
                    confirmBreakExit = true
                }
                .disabled(!available.contains(.clockOut))
            case .ended:
                Button("新しい勤務日を開始") { start(expected: context) }
                    .disabled(!settingsValid || !available.contains(.start))
                Button("直前の勤務日を再開") { model.performAction(.resume, expected: context) }
                    .disabled(!available.contains(.resume))
            }
        }

        private func stateLabel(_ state: WorkdayState) -> String {
            switch state {
            case .working: "勤務中"
            case .onBreak: "休憩中"
            case .ended: "退勤済み"
            }
        }

        private func reviewTimeLabel(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute().second())
        }

        private func timeLabel(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute())
        }

        private func duration(_ seconds: ClosedRange<Int64>, roundUp: Bool = false) -> String {
            func minutes(_ value: Int64) -> Int64 {
                value / 60 + (roundUp && value % 60 > 0 ? 1 : 0)
            }
            let lower = minutes(seconds.lowerBound)
            let upper = minutes(seconds.upperBound)
            return lower == upper ? "\(lower)分" : "\(lower)〜\(upper)分"
        }
    }

    extension WorktimeMenu {
        private var reminderSettings: some View {
            DisclosureGroup("勤務の通知") {
                Text("希望退勤（適格な場合）または希望がない場合の退勤見込みを基準に通知します。過ぎた時刻には通知しません。")
                    .font(.caption)
                if model.remindersSupported {
                    ForEach([ReminderLead.thirty, .fifteen, .five], id: \.rawValue) { lead in
                        Toggle("\(lead.rawValue / 60)分前", isOn: Binding(
                            get: { model.departureLeads.contains(lead) },
                            set: { model.setDepartureLead(lead, enabled: $0) }
                        ))
                    }
                    if model.departureLeads.isEmpty {
                        Text("退勤準備通知は未選択です。").font(.caption)
                    }
                    Toggle("最短目標達成の15分前", isOn: Binding(
                        get: { model.earliestReminderEnabled },
                        set: { model.setEarliestReminder($0) }
                    ))
                    Toggle("参考終業時刻", isOn: Binding(
                        get: { model.referenceReminderEnabled },
                        set: { model.setReferenceReminder($0) }
                    ))
                    Text("最短達成と参考終業は独立した通知です。勤務実績の確定ではありません。")
                        .font(.caption)
                    if model.remindersEnabled {
                        Button("通知を無効にする") { model.disableReminders() }
                        Button("通知許可を確認する") { model.enableReminders() }
                    } else {
                        Button("通知を有効にする") { model.enableReminders() }
                    }
                    Text(model.reminderStatus).font(.caption)
                } else {
                    Text("通知は.appからの起動時に利用できます。").font(.caption)
                }
            }
            .disabled(model.requestingReminderPermission)
        }

        @ViewBuilder
        private func reviewSection(_ glance: WorktimeGlance) -> some View {
            if let notice = model.reviewNotice {
                Text(notice).font(.caption)
            }
            if let proposal = model.reviewProposal {
                Divider()
                Text("訂正案（未保存）").font(.headline)
                if proposal.before.day.id != glance.day.id {
                    Text("過去勤務日：\(reviewTimeLabel(proposal.before.day.intervals.first?.start ?? 0))")
                        .font(.caption)
                }
                Text("\(reviewTimeLabel(proposal.selection.start))〜\(reviewTimeLabel(proposal.selection.end))")
                    .font(.caption)
                Text("分類：\(classificationLabel(proposal.classification))")
                Text("試算時刻：\(reviewTimeLabel(proposal.observedAt))").font(.caption)
                Text("訂正前の実働：\(workedLabel(proposal.before))")
                Text("訂正後の実働：\(workedLabel(proposal.after))")
                Text("退勤見込み：\(goalLabel(proposal.before.forecast.goal)) → \(goalLabel(proposal.after.forecast.goal))")
                    .font(.caption)
                HStack {
                    Button("キャンセル") { model.cancelReview() }
                    Button("訂正を保存") { model.acceptReview() }
                        .disabled(!model.allowsOptionalJournalMutation)
                }
            } else if !glance.reviewableGaps.isEmpty {
                Divider()
                ReviewRangeSettingsView(model: model, glance: glance)
                    .disabled(!model.allowsOptionalJournalMutation)
            }
        }

        private func classificationLabel(_ classification: ReviewClassification) -> String {
            switch classification {
            case .work: "勤務"
            case .rest: "休憩"
            case .gap: "非勤務"
            }
        }

        private func workedLabel(_ glance: WorktimeGlance) -> String {
            let bounds = glance.snapshot.bounds
            return bounds.lower == bounds.upper ? "\(bounds.lower)秒" : "\(bounds.lower)〜\(bounds.upper)秒"
        }

        private func goalLabel(_ goal: GoalForecast) -> String {
            switch goal {
            case let .projected(_, departure): timeLabel(departure)
            case .reached: "目標達成"
            case .uncertain: "要確認"
            case .onBreak: "休憩中"
            case .ended: "退勤済み"
            }
        }
    }
#endif
