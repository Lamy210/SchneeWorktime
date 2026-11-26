#if os(macOS)
    import WorktimeApplication

    extension DesktopModel {
        var canPreviewSchemaTwoReset: Bool {
            !ready && controller == nil && sessionLock != nil && schemaTwoInspection == nil &&
                schemaTwoWorkSession != nil && !schemaTwoWorkBusy &&
                !maintenanceInProgress && !choosingBackupDestination
        }

        func previewSchemaTwoReset() throws -> JournalV2ConfirmedReset {
            guard canPreviewSchemaTwoReset, let current = schemaTwoWorkSession else {
                throw JournalV2ConfirmedResetError.staleConfirmation
            }
            return try current.previewConfirmedReset(matching: current.workActionContext, sample: Self.sample())
        }

        func canConfirmSchemaTwoReset(_ confirmation: JournalV2ConfirmedReset) -> Bool {
            canPreviewSchemaTwoReset && schemaTwoWorkSession?.isCurrent(confirmation) == true &&
                reminderCoordinator != nil && !reminderRunning && !requestingReminderPermission
        }

        func confirmSchemaTwoReset(_ confirmation: JournalV2ConfirmedReset, consent: String) {
            guard consent == "削除", canConfirmSchemaTwoReset(confirmation),
                  let coordinator = reminderCoordinator
            else {
                schemaTwoResetNotice = "確認内容または記録状態が変わりました。削除せず再確認してください。"
                return
            }
            maintenanceInProgress = true
            reminderStateUntrusted = true
            clearBackupInspection()
            backupNotice = nil
            schemaTwoResetNotice = "所有通知の取消を確認中"
            Task {
                await finishSchemaTwoReset(confirmation, consent: consent, coordinator: coordinator)
            }
        }

        private func finishSchemaTwoReset(
            _ confirmation: JournalV2ConfirmedReset, consent: String, coordinator: DesktopReminderCoordinator
        ) async {
            var committed = false
            do {
                let result = try await coordinator.reconcile(latest: { nil }, now: { try Self.sample().wall })
                if result == .settled, maintenanceInProgress, sessionLock != nil,
                   !ready, controller == nil, !schemaTwoWorkBusy,
                   var current = schemaTwoWorkSession, current.isCurrent(confirmation) {
                    try current.commitConfirmedReset(confirmation, consent: consent, sample: Self.sample())
                    committed = true
                    schemaTwoResetNotice = "現在のDB内の勤務履歴を初期化しました。外部ファイルは残ります。"
                } else {
                    schemaTwoResetNotice = "通知停止または保存版を確認できず、初期化を中止しました。"
                }
            } catch {
                schemaTwoResetNotice = "初期化結果は未確認です。再操作せず再読込結果を確認してください。"
            }
            // On every outcome discard the writable controller. Never create a
            // replacement DB or retry deletion after an uncertain result.
            maintenanceInProgress = false
            open(create: false)
            if committed, schemaTwoInspection == nil {
                schemaTwoResetNotice = "初期化後の再読込に失敗しました。新規作成せず既存DBを確認してください。"
            }
        }
    }
#endif
