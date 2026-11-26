#if os(macOS)
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        var remindersSupported: Bool {
            reminderCoordinator != nil
        }

        var reminderEditingAllowed: Bool {
            let active = ready && controller != nil || schemaTwoWorkSession != nil
            return active && sessionLock != nil && !maintenanceInProgress &&
                !choosingBackupDestination && !schemaTwoWorkBusy
        }

        func enableReminders() {
            guard reminderEditingAllowed, let reminderCoordinator, !requestingReminderPermission,
                  !reminderRunning else { return }
            requestingReminderPermission = true
            Task {
                defer { requestingReminderPermission = false }
                do {
                    let granted = try await reminderCoordinator.enable()
                    remindersEnabled = granted
                    UserDefaults.standard.set(granted, forKey: "departureReminderEnabled")
                    reminderStatus = granted ? "通知を設定中" : "macOSの通知設定を確認してください。"
                    queueReminders(force: true)
                } catch {
                    reminderStatus = "通知許可を確認できません。勤務記録は継続します。"
                }
            }
        }

        func setDepartureLead(_ lead: ReminderLead, enabled: Bool) {
            guard reminderEditingAllowed, !requestingReminderPermission else { return }
            var selected = departureLeads
            if enabled {
                selected.insert(lead)
            } else {
                selected.remove(lead)
            }
            guard selected != departureLeads else { return }
            departureLeads = selected
            UserDefaults.standard.set(ReminderLeadSettings.encode(selected), forKey: "departureReminderLeads")
            queueReminders(force: true)
        }

        func setEarliestReminder(_ enabled: Bool) {
            guard reminderEditingAllowed, !requestingReminderPermission else { return }
            earliestReminderEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "earliestReminderEnabled")
            queueReminders(force: true)
        }

        func setReferenceReminder(_ enabled: Bool) {
            guard reminderEditingAllowed, !requestingReminderPermission else { return }
            referenceReminderEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "referenceReminderEnabled")
            queueReminders(force: true)
        }

        func disableReminders() {
            guard !maintenanceInProgress, !schemaTwoWorkBusy, sessionLock != nil,
                  !requestingReminderPermission else { return }
            remindersEnabled = false
            UserDefaults.standard.set(false, forKey: "departureReminderEnabled")
            reminderStatus = "通知予約の取消を確認中"
            queueReminders(force: true)
        }

        private func latestReminderState() throws -> ReminderSyncState? {
            guard remindersEnabled, !reminderStateUntrusted else { return nil }
            do {
                let observed = try Self.sample()
                let earliest: Set<ReminderLead> = earliestReminderEnabled ? [.fifteen] : []
                if let current = schemaTwoWorkSession {
                    guard !ready, controller == nil, !schemaTwoWorkBusy else {
                        throw ReminderDeliveryError.invalidRequest
                    }
                    return try current.reminderState(
                        sample: observed, departureLeads: departureLeads,
                        earliestLeads: earliest, referenceEnabled: referenceReminderEnabled
                    )
                }
                guard ready, let controller else { throw ReminderDeliveryError.invalidRequest }
                return try controller.reminderState(
                    sample: observed, departureLeads: departureLeads,
                    earliestLeads: earliest, referenceEnabled: referenceReminderEnabled
                )
            } catch is ApplicationClockError {
                return nil
            }
        }

        func queueReminders(force: Bool = false) {
            guard !maintenanceInProgress else { return }
            if force {
                nextReminderCheck = 0
            }
            guard let reminderCoordinator, sessionLock != nil, !reminderRunning,
                  ready || schemaTwoWorkSession != nil || reminderStateUntrusted || !remindersEnabled else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            guard uptime >= nextReminderCheck else { return }
            nextReminderCheck = uptime + 15
            reminderRunning = true
            Task {
                defer { reminderRunning = false }
                do {
                    let result = try await reminderCoordinator.reconcile(
                        latest: { try self.latestReminderState() }, now: { try Self.sample().wall }
                    )
                    updateReminderStatus(result)
                } catch {
                    // An error may occur after the OS accepted an add request.
                    // Cancel owned IDs without assuming that a failed read
                    // proves there are no pending notifications.
                    reminderStateUntrusted = true
                    do {
                        let cleanup = try await reminderCoordinator.reconcile(
                            latest: { nil }, now: { try Self.sample().wall }
                        )
                        reminderStatus = cleanup == .settled
                            ? "通知の状態を確認できず所有通知を停止しました。"
                            : "通知の取消が未収束です。再確認してください。"
                    } catch {
                        reminderStatus = "通知の取消を確認できません。macOS通知設定を確認してください。"
                    }
                }
            }
        }

        private func updateReminderStatus(_ result: ReminderSyncResult) {
            switch result {
            case .settled:
                if remindersEnabled {
                    reminderStatus = reminderStateUntrusted ? "記録または時計を確認できないため通知停止" : "通知予約の更新完了（配信はOS依存）"
                } else {
                    reminderStatus = "通知は無効です。"
                }
            case .permissionUnavailable:
                reminderStatus = "macOSの通知設定を確認してください。"
            case .busy, .superseded, .cancellationPending:
                reminderStatus = "通知予約を再確認します。"
            }
        }
    }

#endif
