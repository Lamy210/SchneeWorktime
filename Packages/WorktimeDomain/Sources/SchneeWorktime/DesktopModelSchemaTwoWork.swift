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
            defer {
                schemaTwoWorkBusy = false
                queueReminders(force: true)
            }
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
                var opened: JournalV2WorktimeController
                if createNew {
                    opened = try JournalV2WorktimeController(
                        url: url, createIfMissing: true, requireNew: true, sample: sample
                    )
                } else {
                    guard let preview = schemaTwoInspection else {
                        throw JournalV2WorkActionError.staleContext
                    }
                    // Fail closed if another process changed the full Journal or
                    // checkpoint while the notification cancellation was pending.
                    opened = try preview.openWorkSession(url: url, sample: sample)
                }
                let current = try opened.refresh(sample: sample)
                schemaTwoWorkSession = opened
                schemaTwoWorkGlance = current
                schemaTwoInspection = nil
                schemaTwoWorkNotice = nil
                reminderStateUntrusted = false
            } catch {
                schemaTwoSessionFailed(error)
            }
        }

        func schemaTwoClockInSettings(profile: WorkdayProfile) throws -> JournalV2ClockInSettings {
            do {
                return try JournalV2ClockInSettings(
                    profile: profile, timeZoneID: TimeZone.current.identifier,
                    wallTime: ReferencePreferences.wallTime()
                )
            } catch is ReferenceTimeError {
                throw JournalV2ClockInSettingsError.invalidReference
            }
        }

        func performSchemaTwoWork(
            _ command: WorkdayCommand, matching expected: JournalV2WorkActionContext,
            clockInSettings: JournalV2ClockInSettings? = nil
        ) {
            guard !schemaTwoWorkBusy, !maintenanceInProgress, !choosingBackupDestination,
                  !ready, controller == nil, sessionLock != nil,
                  var current = schemaTwoWorkSession
            else {
                schemaTwoWorkNotice = "記録セッションが変わりました。操作を再確認してください。"
                return
            }
            do {
                let sample = try Self.sample()
                let updated: WorktimeGlance? = if case let .clockIn(id, profile) = command {
                    try confirmedSchemaTwoClockIn(
                        id: id, profile: profile, displayed: clockInSettings,
                        matching: expected, sample: sample, controller: &current
                    )
                } else {
                    try current.performConfirmedAfterRoutineObservation(command, matching: expected, sample: sample)
                }
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
                queueReminders(force: true)
            } catch JournalV2WorkActionError.staleContext {
                schemaTwoWorkNotice = "勤務記録・設定・タイムゾーンが更新されました。操作内容を再確認してください。"
            } catch JournalV2ClockInSettingsError.invalidReference {
                schemaTwoWorkNotice = "参考終業時刻の設定を確認してください。"
            } catch JournalV2WorkActionError.invalidTransition {
                schemaTwoWorkNotice = "勤務状態が操作と一致しません。操作を再確認してください。"
            } catch JournalV2WorkActionError.insufficientCapacity {
                schemaTwoWorkNotice = "Journalの残容量が不足しています。履歴を保全してください。"
            } catch {
                schemaTwoSessionFailed(error)
            }
        }

        private func confirmedSchemaTwoClockIn(
            id: UUID, profile: WorkdayProfile, displayed: JournalV2ClockInSettings?,
            matching expected: JournalV2WorkActionContext, sample: ClockSample,
            controller: inout JournalV2WorktimeController
        ) throws -> WorktimeGlance? {
            guard let displayed else { throw JournalV2WorkActionError.staleContext }
            let latest = try schemaTwoClockInSettings(profile: profile)
            return try controller.performConfirmedClockIn(
                id: id, displayed: displayed, current: latest, matching: expected, sample: sample
            )
        }

        func refreshSchemaTwoWorkSession() {
            guard var current = schemaTwoWorkSession else { return }
            do {
                let previousGoal = schemaTwoWorkGlance?.forecast.goal
                let updated = try current.refresh(sample: Self.sample())
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                queueReminders(force: previousGoal != updated?.forecast.goal)
            } catch {
                schemaTwoSessionFailed(error)
            }
        }

        func stopSchemaTwoObservation() {
            guard schemaTwoWorkSession != nil, !schemaTwoWorkBusy else { return }
            // Stopping observation is not a clock-out and does not delete the Journal.
            open(create: false)
        }

        func schemaTwoSessionFailed(_ error: Error) {
            schemaTwoWorkSession = nil
            schemaTwoWorkGlance = nil
            schemaTwoInspection = nil
            schemaTwoWorkNotice = "観測または保存を確認できません。再操作せず、原本を保全してください：\(error)"
            reminderStateUntrusted = true
            queueReminders(force: true)
        }
    }
#endif
