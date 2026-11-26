#if os(macOS)
    import Foundation
    import WorktimeApplication

    extension DesktopModel {
        var canChooseSchemaTwoRollback: Bool {
            !ready && controller == nil && sessionLock != nil && schemaTwoInspection == nil &&
                schemaTwoActionContext?.day?.state == .ended && !schemaTwoWorkBusy &&
                !maintenanceInProgress && !choosingBackupDestination
        }

        func chooseSchemaTwoRollback() {
            guard canChooseSchemaTwoRollback, let expected = schemaTwoActionContext else { return }
            schemaTwoRollback = nil
            schemaTwoRollbackNotice = nil
            choosingBackupDestination = true
            defer { choosingBackupDestination = false }
            guard let source = BackupInspectionPanel.choose(initialDirectory: nil, forRollback: true) else { return }
            guard schemaTwoActionContext == expected, let current = schemaTwoWorkSession else {
                schemaTwoRollbackNotice = "記録が変わりました。候補を再選択してください。"
                return
            }
            do {
                schemaTwoRollback = try current.previewConfirmedRollback(
                    file: source, matching: expected, sample: Self.sample()
                )
            } catch {
                schemaTwoRollbackNotice = "候補を使用できません。同一世代の以前の終了済み履歴を指定してください。"
            }
        }

        var canConfirmSchemaTwoRollback: Bool {
            guard canChooseSchemaTwoRollback, let confirmation = schemaTwoRollback else { return false }
            return schemaTwoWorkSession?.isCurrent(confirmation) == true && reminderCoordinator != nil &&
                !reminderRunning && !requestingReminderPermission
        }

        func cancelSchemaTwoRollback() {
            guard !maintenanceInProgress, !choosingBackupDestination else { return }
            schemaTwoRollback = nil
            schemaTwoRollbackNotice = nil
        }

        func confirmSchemaTwoRollback(_ displayedID: UUID, acknowledged: Bool) {
            guard acknowledged, canConfirmSchemaTwoRollback, let confirmation = schemaTwoRollback,
                  confirmation.id == displayedID
            else { return }
            choosingBackupDestination = true
            let directory = WorktimeExportFormat.backup.chooseDirectory(initialDirectory: nil)
            choosingBackupDestination = false
            guard let directory else { return }
            guard canConfirmSchemaTwoRollback, schemaTwoRollback?.id == displayedID,
                  schemaTwoWorkSession?.isCurrent(confirmation) == true, let coordinator = reminderCoordinator
            else {
                schemaTwoRollback = nil
                schemaTwoRollbackNotice = "記録または通知状態が変わりました。復元候補を再確認してください。"
                return
            }
            guard isExternalRollbackDirectory(directory) else {
                schemaTwoRollbackNotice = "アプリのDBフォルダ外にある所有者専用の保全先を指定してください。"
                return
            }
            let destination = directory.appendingPathComponent(
                "SchneeWorktime-schema2-before-rollback-\(UUID().uuidString).json"
            )
            maintenanceInProgress = true
            schemaTwoRollback = nil
            schemaTwoRollbackNotice = "所有通知の取消と現履歴の保全を確認中"
            reminderStateUntrusted = true
            Task {
                await finishSchemaTwoRollback(confirmation, destination: destination, coordinator: coordinator)
            }
        }

        private func isExternalRollbackDirectory(_ directory: URL) -> Bool {
            guard let source = try? databaseURL().deletingLastPathComponent() else { return false }
            return !directory.resolvingSymlinksInPath().pathComponents.starts(
                with: source.resolvingSymlinksInPath().pathComponents
            )
        }

        private func finishSchemaTwoRollback(
            _ confirmation: JournalV2ConfirmedRollback, destination: URL,
            coordinator: DesktopReminderCoordinator
        ) async {
            var committed = false
            do {
                let result = try await coordinator.reconcile(latest: { nil }, now: { try Self.sample().wall })
                if result == .settled, maintenanceInProgress, sessionLock != nil,
                   !ready, controller == nil, !schemaTwoWorkBusy,
                   var current = schemaTwoWorkSession, current.isCurrent(confirmation) {
                    try current.commitConfirmedRollback(
                        confirmation, preserveCurrentAt: destination, sample: Self.sample()
                    )
                    committed = true
                    schemaTwoRollbackNotice = "復元しました。保全ファイル：\(destination.path)"
                } else {
                    schemaTwoRollbackNotice = "通知停止または保存版を確認できないため復元を中止しました。"
                }
            } catch {
                schemaTwoRollbackNotice = "復元結果は未確認です。再操作せず原本と保全先を確認：\(destination.path)"
            }
            // Discard the old writable controller on every outcome. Reopen
            // read-only, never create a fresh database after uncertainty.
            maintenanceInProgress = false
            open(create: false)
            if committed, schemaTwoInspection == nil {
                schemaTwoRollbackNotice = "復元後の再読込に失敗しました。保全ファイル：\(destination.path)"
            }
        }
    }
#endif
