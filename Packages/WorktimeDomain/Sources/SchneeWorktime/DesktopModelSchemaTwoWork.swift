#if os(macOS)
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        var schemaTwoActionContext: JournalV2WorkActionContext? {
            schemaTwoWorkSession?.workActionContext
        }

        var schemaTwoCanCreate: Bool {
            guard !ready, controller == nil, schemaTwoWorkSession == nil,
                  let url = try? databaseURL(),
                  let decision = try? DesktopStorageLaunchGuard.decide(
                      url: url, createIfMissing: true, allowLegacyDevelopment: false
                  )
            else { return false }
            return decision == .newInstallRequiresSchemaTwoUI
        }

        /// Never turn a read-only Journal inspection into recovery or attendance
        /// automatically. Notification cancellation must settle before opt-in.
        func activateSchemaTwoWorkSession(createNew: Bool) {
            guard !schemaTwoWorkBusy, !ready, controller == nil,
                  schemaTwoWorkSession == nil, !maintenanceInProgress,
                  !choosingBackupDestination, !reminderRunning,
                  !requestingReminderPermission, let coordinator = reminderCoordinator
            else {
                schemaTwoWorkNotice = "通知停止と記録状態を確認できません。操作を中止しました。"
                return
            }
            schemaTwoWorkBusy = true
            schemaTwoWorkNotice = "所有通知の取消を確認中。保存形式は変更していません。"
            Task {
                await finishSchemaTwoActivation(createNew: createNew, coordinator: coordinator)
            }
        }

        private func finishSchemaTwoActivation(
            createNew: Bool, coordinator: DesktopReminderCoordinator
        ) async {
            defer { schemaTwoWorkBusy = false }
            do {
                let stopped = try await coordinator.reconcile(latest: { nil }, now: { try Self.sample().wall })
                guard stopped == .settled, !ready, controller == nil,
                      schemaTwoWorkSession == nil, !maintenanceInProgress
                else {
                    schemaTwoWorkNotice = "所有通知の取消が収束していないため、勤務記録を開始できません。"
                    return
                }
                let url = try databaseURL()
                let directory = url.deletingLastPathComponent()
                if createNew, !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                }
                if sessionLock == nil {
                    sessionLock = try LocalSessionLock(directory: directory)
                }
                let decision = try DesktopStorageLaunchGuard.decide(
                    url: url, createIfMissing: createNew, allowLegacyDevelopment: false
                )
                if createNew {
                    guard decision == .newInstallRequiresSchemaTwoUI else {
                        throw JournalV2WorkActionError.staleContext
                    }
                } else {
                    guard decision == .schemaTwoAwaitingUI, schemaTwoInspection != nil else {
                        throw JournalV2WorkActionError.staleContext
                    }
                }
                let sample = try Self.sample()
                var opened = try JournalV2WorktimeController(
                    url: url, createIfMissing: createNew, requireNew: createNew, sample: sample
                )
                let current = try opened.refresh(sample: sample)
                schemaTwoWorkSession = opened
                schemaTwoWorkGlance = current
                schemaTwoInspection = nil
                schemaTwoWorkNotice = nil
                reminderStateUntrusted = true
                queueReminders(force: true)
            } catch {
                schemaTwoSessionFailed(error)
            }
        }

        func performSchemaTwoWork(
            _ command: WorkdayCommand, matching expected: JournalV2WorkActionContext
        ) {
            guard !schemaTwoWorkBusy, !maintenanceInProgress, !choosingBackupDestination,
                  !ready, controller == nil, sessionLock != nil,
                  var current = schemaTwoWorkSession
            else {
                schemaTwoWorkNotice = "記録セッションが変わりました。操作を再確認してください。"
                return
            }
            do {
                let updated = try current.performConfirmed(command, matching: expected, sample: Self.sample())
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
            } catch JournalV2WorkActionError.staleContext {
                schemaTwoWorkNotice = "勤務記録が更新されました。操作内容を再確認してください。"
            } catch JournalV2WorkActionError.invalidTransition {
                schemaTwoWorkNotice = "勤務状態が操作と一致しません。操作を再確認してください。"
            } catch JournalV2WorkActionError.insufficientCapacity {
                schemaTwoWorkNotice = "Journalの残容量が不足しています。履歴を保全してください。"
            } catch {
                schemaTwoSessionFailed(error)
            }
        }

        func refreshSchemaTwoWorkSession() {
            guard var current = schemaTwoWorkSession else { return }
            do {
                let updated = try current.refresh(sample: Self.sample())
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
            } catch {
                schemaTwoSessionFailed(error)
            }
        }

        func stopSchemaTwoObservation() {
            guard schemaTwoWorkSession != nil, !schemaTwoWorkBusy else { return }
            // Stopping observation is not a clock-out and does not delete the Journal.
            open(create: false)
        }

        private func schemaTwoSessionFailed(_ error: Error) {
            schemaTwoWorkSession = nil
            schemaTwoWorkGlance = nil
            schemaTwoInspection = nil
            schemaTwoWorkNotice = "観測または保存を確認できません。再操作せず、原本を保全してください：\(error)"
            reminderStateUntrusted = true
            queueReminders(force: true)
        }
    }
#endif
