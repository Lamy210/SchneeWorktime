#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    final class DesktopModel: ObservableObject {
        @Published private(set) var glance: WorktimeGlance? {
            didSet { updateObservationTimer() }
        }

        @Published private(set) var ready = false
        @Published private(set) var message: String?
        @Published private(set) var reviewProposal: WorktimeReviewProposal?
        @Published private(set) var reviewNotice: String?
        @Published var backupNotice: String?
        @Published var choosingBackupDestination = false
        @Published var backupInspection: BackupInspection?
        @Published var inspectionNotice: String?
        @Published var rollbackProposal: WorktimeRollbackProposal?
        @Published var rollbackNotice: String?
        @Published var maintenanceInProgress = false
        @Published var resetState = DesktopResetState()

        @Published private(set) var remindersEnabled = UserDefaults.standard.bool(forKey: "departureReminderEnabled")
        @Published private(set) var departureLeads = ReminderLeadSettings.decode(
            UserDefaults.standard.string(forKey: "departureReminderLeads")
        )
        @Published private(set) var earliestReminderEnabled = UserDefaults.standard.bool(
            forKey: "earliestReminderEnabled"
        )
        @Published private(set) var referenceReminderEnabled = UserDefaults.standard.bool(
            forKey: "referenceReminderEnabled"
        )
        @Published private(set) var reminderStatus = ""
        @Published private(set) var requestingReminderPermission = false

        private(set) var controller: WorktimeController?
        private(set) var sessionLock: LocalSessionLock?
        private(set) var reminderCoordinator: DesktopReminderCoordinator?
        private(set) var reminderRunning = false
        private var nextReminderCheck: Double = 0
        private var reminderStateUntrusted = false
        private let observationTimer = DesktopObservationTimer()

        init() {
            if DesktopReminderCoordinator.supported {
                reminderCoordinator = DesktopReminderCoordinator()
            }
            open(create: false)
            updateObservationTimer()
            observationTimer.observeLifecycle { [weak self] in
                self?.nextReminderCheck = 0
                self?.tick()
            }
        }

        private func updateObservationTimer() {
            observationTimer.update(to: ObservationCadence(dayState: glance?.day.state)) { [weak self] in
                self?.tick()
            }
        }

        func open(create: Bool) {
            guard !maintenanceInProgress, !choosingBackupDestination else { return }
            rollbackProposal = nil
            resetState.proposal = nil
            cancelReview()
            controller = nil
            ready = false
            glance = nil
            do {
                let url = try databaseURL()
                let directory = url.deletingLastPathComponent()
                if create, !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                }
                if sessionLock == nil {
                    sessionLock = try LocalSessionLock(directory: directory)
                }
                if create, FileManager.default.fileExists(atPath: url.path) {
                    message = "既存のデータベースがあります。初期化せず再読込してください。"
                    reminderStateUntrusted = true
                    queueReminders(force: true)
                    return
                }
                let sample = try Self.sample()
                var opened = try WorktimeController(url: url, createIfMissing: create, sample: sample)
                glance = try opened.refresh(sample: sample)
                controller = opened
                ready = true
                message = nil
                reminderStateUntrusted = false
                queueReminders(force: true)
            } catch {
                fail(error)
            }
        }

        func suspendForMaintenance() {
            ready = false
            glance = nil
        }

        func recentHistory(offset: Int = 0, previous: WorktimeHistory? = nil) throws -> WorktimeHistory? {
            try controller?.recentHistory(now: Self.sample().wall, offset: offset, previous: previous)
        }

        func historicalReviewContext(dayID: UUID, history: WorktimeHistory) throws -> HistoricalReviewContext {
            guard ready, !choosingBackupDestination, reviewProposal == nil, let controller else {
                throw HistoricalReviewError.staleContext
            }
            return try controller.historicalReviewContext(dayID: dayID, history: history, sample: Self.sample())
        }

        var actionContext: PanelActionContext {
            PanelActionContext(
                day: glance?.day,
                enabled: ready && reviewProposal == nil && !choosingBackupDestination,
                canOpenWorkday: controller?.journalCapacity.canOpenWorkday == true
            )
        }

        func performAction(
            _ action: PanelWorkAction, expected: PanelActionContext,
            confirmed: Bool = false, profile: WorkdayProfile? = nil
        ) {
            guard let command = actionContext.command(
                for: action, matching: expected, at: glance?.observedAt ?? 0,
                confirmed: confirmed, profile: profile
            ) else { return }
            perform(command)
        }

        private func perform(_ command: WorkdayCommand) {
            cancelReview()
            guard var current = controller else { return }
            do {
                let sample = try Self.sample()
                let prepared = try captureReference(for: command, at: sample.wall)
                glance = try current.perform(prepared, sample: sample)
                controller = current
                queueReminders(force: true)
            } catch {
                fail(error)
            }
        }

        func prepareReview(
            selection: ObservationGap, classification: ReviewClassification,
            expectedDay: Workday, source: ObservationGap, historical: HistoricalReviewContext? = nil
        ) {
            guard ready, !choosingBackupDestination, reviewProposal == nil,
                  let displayed = historical?.glance ?? glance,
                  displayed.day == expectedDay, displayed.reviewableGaps.contains(source),
                  selection.start >= source.start, selection.end <= source.end, selection.start < selection.end,
                  var current = controller
            else {
                reviewNotice = "要確認区間が変わったため、選択内容を再確認してください。"
                return
            }
            do {
                let sample = try Self.sample()
                let proposal: WorktimeReviewProposal
                if let historical {
                    proposal = try current.previewHistoricalReview(
                        historical, selection: selection, source: source, classification: classification, sample: sample
                    )
                } else {
                    proposal = try current.previewReview(
                        selection: selection, classification: classification, sample: sample
                    )
                    glance = proposal.before
                }
                controller = current
                reviewProposal = proposal
                reviewNotice = nil
                queueReminders(force: true)
            } catch HistoricalReviewError.staleContext {
                reviewNotice = "履歴が更新されました。過去勤務日を再選択してください。"
            } catch {
                fail(error)
            }
        }

        func cancelReview() {
            reviewProposal = nil
            reviewNotice = nil
        }

        func acceptReview() {
            guard var current = controller, let proposal = reviewProposal else { return }
            do {
                glance = try current.commitReview(proposal, sample: Self.sample())
                controller = current
                cancelReview()
                queueReminders(force: true)
            } catch {
                if error is CommittedCheckpointError || current.isCurrent(proposal) {
                    fail(error)
                } else {
                    do {
                        glance = try current.refresh(sample: Self.sample())
                        controller = current
                        invalidateReview()
                        queueReminders(force: true)
                    } catch {
                        fail(error)
                    }
                }
            }
        }

        private func invalidateReview() {
            reviewProposal = nil
            reviewNotice = "記録が更新されたため、訂正案をもう一度確認してください。"
        }

        private func tick() {
            guard !maintenanceInProgress else { return }
            guard var current = controller else {
                queueReminders()
                return
            }
            do {
                let previousGoal = glance?.forecast.goal
                glance = try current.refresh(sample: Self.sample())
                controller = current
                if let proposal = rollbackProposal, !current.isCurrent(proposal) {
                    rollbackProposal = nil
                    rollbackNotice = "記録が更新されました。復元候補を再選択してください。"
                }
                queueReminders(force: previousGoal != glance?.forecast.goal)
                if let proposal = reviewProposal, !current.isCurrent(proposal) {
                    invalidateReview()
                }
            } catch {
                fail(error)
            }
        }

        private func fail(_ error: Error) {
            rollbackProposal = nil
            cancelReview()
            controller = nil
            glance = nil
            ready = false
            reminderStateUntrusted = true
            queueReminders(force: true)
            if error is CommittedCheckpointError {
                message = "操作は保存済みですが観測情報の保存に失敗しました。再操作せず既存データを再読込してください。"
            } else if let lockError = error as? LocalSessionLockError {
                switch lockError {
                case .alreadyLocked:
                    message = "別の起動中のSchneeWorktimeを終了してから再読込してください。"
                case .unsafeDirectory, .unsafeLockFile:
                    message = "保存先の所有者・権限・リンクを確認してください。記録は変更しません。"
                case .system:
                    message = "保存先の排他ロックを取得できません。記録を停止しました。"
                }
            } else {
                message = "記録を停止：\(error)。既存DBを上書きせず、時刻・権限・バックアップを確認してください。"
            }
        }

        func databaseURL() throws -> URL {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )
            return support.appendingPathComponent("SchneeWorktime", isDirectory: true)
                .appendingPathComponent("worktime.sqlite")
        }

        static func sample() throws -> ClockSample {
            guard let wall = Int64(exactly: Date().timeIntervalSince1970.rounded(.down)) else {
                throw ApplicationClockError.invalidSample
            }
            return try ClockSample(wall: wall, uptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    extension DesktopModel {
        var remindersSupported: Bool {
            reminderCoordinator != nil
        }

        func enableReminders() {
            guard ready, sessionLock != nil, let reminderCoordinator, !requestingReminderPermission else { return }
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
            guard ready, sessionLock != nil, !requestingReminderPermission else { return }
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
            guard ready, sessionLock != nil, !requestingReminderPermission else { return }
            earliestReminderEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "earliestReminderEnabled")
            queueReminders(force: true)
        }

        func setReferenceReminder(_ enabled: Bool) {
            guard ready, sessionLock != nil, !requestingReminderPermission else { return }
            referenceReminderEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "referenceReminderEnabled")
            queueReminders(force: true)
        }

        func disableReminders() {
            guard !maintenanceInProgress, sessionLock != nil, !requestingReminderPermission else { return }
            remindersEnabled = false
            UserDefaults.standard.set(false, forKey: "departureReminderEnabled")
            reminderStatus = "通知予約の取消を確認中"
            queueReminders(force: true)
        }

        private func latestReminderState() throws -> ReminderSyncState? {
            guard remindersEnabled, !reminderStateUntrusted else { return nil }
            guard ready, let controller else { throw ReminderDeliveryError.invalidRequest }
            do {
                return try controller.reminderState(
                    sample: Self.sample(), departureLeads: departureLeads,
                    earliestLeads: earliestReminderEnabled ? [.fifteen] : [],
                    referenceEnabled: referenceReminderEnabled
                )
            } catch is ApplicationClockError {
                return nil
            }
        }

        private func queueReminders(force: Bool = false) {
            guard !maintenanceInProgress else { return }
            if force {
                nextReminderCheck = 0
            }
            guard let reminderCoordinator, sessionLock != nil, !reminderRunning,
                  ready || reminderStateUntrusted || !remindersEnabled else { return }
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
                    reminderStatus = "通知を更新できませんでした。勤務記録は変更しません。"
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

    extension DesktopModel {
        func confirmDesiredDeparture(_ proposal: DesiredDepartureProposal, warningAcknowledged: Bool) throws {
            guard ready, !choosingBackupDestination, reviewProposal == nil, var current = controller else {
                throw DesiredDepartureSaveError.staleProposal
            }
            do {
                glance = try current.commitDesiredDeparture(
                    proposal, warningAcknowledged: warningAcknowledged, sample: Self.sample()
                )
                controller = current
                queueReminders(force: true)
            } catch let error as DesiredDepartureSaveError {
                throw error
            } catch {
                fail(error)
                throw error
            }
        }

        func clearDesiredDeparture(expectedDay: Workday) throws {
            guard ready, !choosingBackupDestination, reviewProposal == nil, var current = controller else {
                throw DesiredDepartureSaveError.staleProposal
            }
            do {
                glance = try current.clearDesiredDeparture(expectedDay: expectedDay, sample: Self.sample())
                controller = current
                queueReminders(force: true)
            } catch let error as DesiredDepartureSaveError {
                throw error
            } catch {
                fail(error)
                throw error
            }
        }
    }

    extension DesktopModel {
        func setFutureRest(minutes: Int?, expectedDay: Workday) throws {
            guard ready, !choosingBackupDestination, reviewProposal == nil,
                  glance?.day == expectedDay, var current = controller
            else { throw FutureRestChangeError.staleContext }
            do {
                glance = try current.setFutureRest(minutes: minutes, expectedDay: expectedDay, sample: Self.sample())
                controller = current
                queueReminders(force: true)
            } catch let error as FutureRestChangeError {
                throw error
            } catch {
                fail(error)
                throw error
            }
        }
    }

    extension DesktopModel {
        func confirmBoundaryCorrection(
            stale: Error, isCurrent: (WorktimeController) -> Bool,
            commit: (inout WorktimeController) throws -> WorktimeGlance?
        ) throws {
            guard ready, !choosingBackupDestination, reviewProposal == nil,
                  var current = controller, isCurrent(current)
            else { throw stale }
            do {
                glance = try commit(&current)
                controller = current
                queueReminders(force: true)
            } catch let error as RestEndInteractionError {
                throw error
            } catch let error as ClockOutInteractionError {
                throw error
            } catch let error as RetrospectiveStartError {
                throw error
            } catch {
                fail(error)
                throw error
            }
        }
    }
#endif
