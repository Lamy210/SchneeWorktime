#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    final class DesktopModel: ObservableObject {
        @Published private(set) var glance: WorktimeGlance?
        @Published private(set) var ready = false
        @Published private(set) var message: String?
        @Published private(set) var reviewProposal: WorktimeReviewProposal?
        @Published private(set) var reviewNotice: String?
        @Published private(set) var backupNotice: String?
        @Published private(set) var choosingBackupDestination = false
        @Published private(set) var backupInspection: BackupInspection?
        @Published private(set) var inspectionNotice: String?
        @Published private(set) var rollbackProposal: WorktimeRollbackProposal?
        @Published private(set) var rollbackNotice: String?
        @Published private(set) var rollbackInProgress = false

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

        private var controller: WorktimeController?
        private var sessionLock: LocalSessionLock?
        private var reminderCoordinator: DesktopReminderCoordinator?
        private var reminderRunning = false
        private var nextReminderCheck: Double = 0
        private var reminderStateUntrusted = false

        init() {
            if DesktopReminderCoordinator.supported {
                reminderCoordinator = DesktopReminderCoordinator()
            }
            open(create: false)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }

        func open(create: Bool) {
            guard !rollbackInProgress, !choosingBackupDestination else { return }
            rollbackProposal = nil
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

        func recentHistory() throws -> WorktimeHistory? {
            try controller?.recentHistory(now: Self.sample().wall)
        }

        var actionContext: PanelActionContext {
            PanelActionContext(
                day: glance?.day,
                enabled: ready && reviewProposal == nil && !choosingBackupDestination
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
            expectedDay: Workday, source: ObservationGap
        ) {
            guard ready, !choosingBackupDestination, reviewProposal == nil,
                  let displayed = glance, displayed.day == expectedDay, displayed.reviewableGaps.contains(source),
                  selection.start >= source.start, selection.end <= source.end, selection.start < selection.end,
                  var current = controller
            else {
                reviewNotice = "要確認区間が変わったため、選択内容を再確認してください。"
                return
            }
            do {
                let sample = try Self.sample()
                let proposal = try current.previewReview(
                    selection: selection, classification: classification, sample: sample
                )
                glance = proposal.before
                controller = current
                reviewProposal = proposal
                reviewNotice = nil
                queueReminders(force: true)
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
                if current.isCurrent(proposal) {
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
            guard !rollbackInProgress else { return }
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
            if let lockError = error as? LocalSessionLockError {
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

        private func databaseURL() throws -> URL {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )
            return support.appendingPathComponent("SchneeWorktime", isDirectory: true)
                .appendingPathComponent("worktime.sqlite")
        }

        private static func sample() throws -> ClockSample {
            guard let wall = Int64(exactly: Date().timeIntervalSince1970.rounded(.down)) else {
                throw ApplicationClockError.invalidSample
            }
            return try ClockSample(wall: wall, uptime: ProcessInfo.processInfo.systemUptime)
        }
    }

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
            guard !rollbackInProgress, sessionLock != nil, !requestingReminderPermission else { return }
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
            guard !rollbackInProgress else { return }
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
            ready = false
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

    extension DesktopModel {
        func previewDesiredDeparture(at instant: Int64) throws -> DesiredDepartureProposal {
            guard ready, !choosingBackupDestination, reviewProposal == nil, let controller else {
                throw DesiredDepartureSaveError.staleProposal
            }
            return try controller.previewDesiredDeparture(at: instant, sample: Self.sample())
        }

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
        private func captureReference(for command: WorkdayCommand, at instant: Int64) throws -> WorkdayCommand {
            guard case let .clockIn(id, profile) = command else { return command }
            return try .clockIn(id: id, profile: capturedProfile(profile, at: instant))
        }

        private func capturedProfile(_ profile: WorkdayProfile, at instant: Int64) throws -> WorkdayProfile {
            let wallTime = try ReferencePreferences.wallTime()
            return try profile.capturingReference(
                at: instant, timeZoneID: TimeZone.current.identifier, wallTime: wallTime
            )
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
        func previewRetrospectiveStart(
            at instant: Int64, targetMinutes: Int, restMinutes: Int
        ) throws -> RetrospectiveStartProposal {
            guard ready, !choosingBackupDestination, reviewProposal == nil, let controller else {
                throw RetrospectiveStartError.staleProposal
            }
            let settings = try NextDaySettings(targetMinutes: targetMinutes, restMinutes: restMinutes)
            return try controller.previewRetrospectiveStart(
                at: instant, profile: capturedProfile(settings.profile, at: instant), sample: Self.sample()
            )
        }

        func confirmRetrospectiveStart(_ proposal: RetrospectiveStartProposal) throws {
            guard ready, !choosingBackupDestination, reviewProposal == nil, var current = controller else {
                throw RetrospectiveStartError.staleProposal
            }
            do {
                glance = try current.commitRetrospectiveStart(proposal, sample: Self.sample())
                controller = current
                queueReminders(force: true)
            } catch let error as RetrospectiveStartError {
                throw error
            } catch {
                fail(error)
                throw error
            }
        }
    }
#endif
