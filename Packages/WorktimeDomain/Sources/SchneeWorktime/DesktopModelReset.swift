#if os(macOS)
    import Foundation
    import WorktimeApplication
    import WorktimeStore

    struct DesktopResetState {
        var proposal: CatalogResetProposal?
        var notice: String?
        var inProgress = false
    }

    extension DesktopModel {
        var canPreviewReset: Bool {
            ready && sessionLock != nil && controller != nil && rollbackProposal == nil &&
                reviewProposal == nil && !choosingBackupDestination && !maintenanceInProgress
        }

        var canConfirmReset: Bool {
            guard canPreviewReset, let proposal = resetState.proposal else { return false }
            return controller?.isCurrent(proposal) == true && reminderCoordinator != nil &&
                !reminderRunning && !requestingReminderPermission
        }

        func prepareReset() {
            guard canPreviewReset, let controller else { return }
            resetState = DesktopResetState()
            do {
                resetState.proposal = try controller.previewReset(sample: Self.sample())
            } catch {
                resetState.notice = "削除候補を確認できません。記録を再読込してください。"
            }
        }

        func cancelReset() {
            guard !maintenanceInProgress else { return }
            resetState = DesktopResetState()
        }

        func confirmReset(version: StoreVersion, confirmation: String) {
            guard confirmation == "削除", canConfirmReset, let proposal = resetState.proposal,
                  proposal.version == version, let coordinator = reminderCoordinator
            else { return }
            resetState.inProgress = true
            resetState.proposal = nil
            maintenanceInProgress = true
            clearBackupInspection()
            backupNotice = nil
            rollbackNotice = nil
            suspendForMaintenance()
            resetState.notice = "所有通知の取消を確認中"
            Task {
                await completeReset(proposal, coordinator: coordinator)
            }
        }

        private func completeReset(_ proposal: CatalogResetProposal, coordinator: DesktopReminderCoordinator) async {
            var committed = false
            do {
                let result = try await coordinator.reconcile(latest: { nil }, now: { try Self.sample().wall })
                if result == .settled, let current = controller, current.isCurrent(proposal), sessionLock != nil {
                    try current.commitReset(proposal, sample: Self.sample())
                    committed = true
                    resetState.notice = "現在のデータベースを初期化しました。保存済みの外部ファイルは残ります。"
                } else {
                    resetState.notice = "通知停止または保存版を確認できず、削除を中止しました。"
                }
            } catch {
                resetState.notice = "削除結果を確認できません。再読込結果を確認してください。"
            }
            maintenanceInProgress = false
            resetState.inProgress = false
            open(create: false)
            if committed, !ready {
                resetState.notice = "初期化後の再読込に失敗しました。新規作成せず再読込してください。"
            }
        }
    }
#endif
