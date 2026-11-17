#if os(macOS)
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        func chooseBackupDestination(format: WorktimeExportFormat = .backup) {
            guard ready, sessionLock != nil, controller != nil, !choosingBackupDestination else { return }
            choosingBackupDestination = true
            defer { choosingBackupDestination = false }

            let initialDirectory = try? databaseURL().deletingLastPathComponent()
            guard let directory = format.chooseDirectory(initialDirectory: initialDirectory) else { return }
            // The modal panel may have allowed observation ticks; consult the current controller after selection.
            guard ready, sessionLock != nil, let current = controller else {
                backupNotice = "勤務記録の再読込が必要です。バックアップは作成していません。"
                return
            }
            let name = format.filename
            let destination = directory.appendingPathComponent(name)
            do {
                try format.write(controller: current, to: destination, now: Self.sample().wall)
                backupNotice = "保存しました：\(name)"
            } catch {
                backupNotice = "保存できませんでした。保存先の所有者・権限、空き容量、勤務記録を確認してください。"
            }
        }

        func chooseBackupForInspection() {
            guard !rollbackInProgress, !choosingBackupDestination else { return }
            choosingBackupDestination = true
            defer { choosingBackupDestination = false }
            backupInspection = nil
            inspectionNotice = nil

            let directory = try? databaseURL().deletingLastPathComponent()
            guard let url = BackupInspectionPanel.choose(initialDirectory: directory) else { return }
            do {
                backupInspection = try BackupInspection(file: url, now: Self.sample().wall)
                inspectionNotice = "構造と勤務履歴の整合性を確認しました。真正性は保証されません。"
            } catch {
                inspectionNotice = "確認できませんでした。形式・所有者・権限・ファイルサイズ・時刻を確認してください。"
            }
        }

        func clearBackupInspection() {
            backupInspection = nil
            inspectionNotice = nil
        }
    }

    extension DesktopModel {
        var canPreviewRollback: Bool {
            ready && sessionLock != nil && glance?.day.state == .ended &&
                reviewProposal == nil && !choosingBackupDestination && !rollbackInProgress
        }

        var canConfirmRollback: Bool {
            canPreviewRollback && rollbackProposal != nil && reminderCoordinator != nil &&
                !reminderRunning && !requestingReminderPermission
        }

        func chooseRollbackSource() {
            guard canPreviewRollback else { return }
            rollbackProposal = nil
            rollbackNotice = nil
            choosingBackupDestination = true
            defer { choosingBackupDestination = false }
            let directory = try? databaseURL().deletingLastPathComponent()
            guard let source = BackupInspectionPanel.choose(initialDirectory: directory, forRollback: true) else {
                return
            }
            guard ready, sessionLock != nil, glance?.day.state == .ended, reviewProposal == nil,
                  let controller
            else {
                rollbackNotice = "勤務記録が変わりました。復元候補を再選択してください。"
                return
            }
            do {
                rollbackProposal = try controller.previewRollback(file: source, sample: Self.sample())
            } catch {
                rollbackNotice = "復元候補を使用できません。同一世代の以前の終了済み履歴とファイル権限を確認してください。"
            }
        }

        func cancelRollback() {
            guard !rollbackInProgress, !choosingBackupDestination else { return }
            rollbackProposal = nil
            rollbackNotice = nil
        }

        func confirmRollback() {
            guard canConfirmRollback, let proposal = rollbackProposal else { return }
            choosingBackupDestination = true
            let directory = WorktimeExportFormat.backup.chooseDirectory(
                initialDirectory: try? databaseURL().deletingLastPathComponent()
            )
            choosingBackupDestination = false
            guard let directory else { return }
            guard canConfirmRollback, let current = controller, current.isCurrent(proposal),
                  let coordinator = reminderCoordinator
            else {
                rollbackProposal = nil
                rollbackNotice = "記録または通知状態が変わりました。復元候補を再確認してください。"
                return
            }
            let name = "SchneeWorktime-before-rollback-\(UUID().uuidString).json"
            let destination = directory.appendingPathComponent(name)
            rollbackInProgress = true
            suspendForRollback()
            rollbackProposal = nil
            rollbackNotice = "通知停止と現履歴の保全を確認中"
            Task {
                await completeRollback(proposal, destination: destination, coordinator: coordinator)
            }
        }

        private func completeRollback(
            _ proposal: WorktimeRollbackProposal, destination: URL, coordinator: DesktopReminderCoordinator
        ) async {
            var committed = false
            do {
                let result = try await coordinator.reconcile(latest: { nil }, now: { try Self.sample().wall })
                if result == .settled, let current = controller, current.isCurrent(proposal), sessionLock != nil {
                    try current.commitRollback(proposal, preserveCurrentAt: destination, sample: Self.sample())
                    committed = true
                    rollbackNotice = "復元しました。保全ファイル：\(destination.path)"
                } else {
                    rollbackNotice = "通知停止を確認できないため復元を中止しました。"
                }
            } catch {
                rollbackNotice = "復元を確認できませんでした。再読込結果と保全先を確認してください：\(destination.path)"
            }
            rollbackInProgress = false
            open(create: false)
            if committed, !ready {
                rollbackNotice = "復元後の再読込に失敗しました。保全ファイル：\(destination.path)"
            }
        }
    }
#endif
