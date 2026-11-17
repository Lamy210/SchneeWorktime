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

        @Published private(set) var remindersEnabled = UserDefaults.standard.bool(forKey: "departureReminderEnabled")
        @Published private(set) var reminderStatus = ""
        @Published private(set) var requestingReminderPermission = false

        private var controller: WorktimeController?
        private var sessionLock: LocalSessionLock?
        private var reminderCoordinator: DesktopReminderCoordinator?
        private var reminderRunning = false
        private var nextReminderCheck: Double = 0
        private var reminderClockUntrusted = false

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
                    return
                }
                let sample = try Self.sample()
                var opened = try WorktimeController(url: url, createIfMissing: create, sample: sample)
                glance = try opened.refresh(sample: sample)
                controller = opened
                ready = true
                message = nil
                reminderClockUntrusted = false
                queueReminders(force: true)
            } catch {
                fail(error)
            }
        }

        func chooseBackupDestination() {
            guard ready, sessionLock != nil, controller != nil, !choosingBackupDestination else { return }
            choosingBackupDestination = true
            defer { choosingBackupDestination = false }

            let panel = NSOpenPanel()
            panel.title = "勤務履歴バックアップの保存先"
            panel.prompt = "このフォルダに保存"
            panel.message = "勤務履歴は暗号化されません。所有者だけがアクセスできるローカルフォルダを選択してください。"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.directoryURL = try? databaseURL().deletingLastPathComponent()

            guard panel.runModal() == .OK, let directory = panel.url else { return }
            // The modal panel may have allowed observation ticks; consult the current controller after selection.
            guard ready, sessionLock != nil, let current = controller else {
                backupNotice = "勤務記録の再読込が必要です。バックアップは作成していません。"
                return
            }
            let name = "SchneeWorktime-backup-\(UUID().uuidString).json"
            let destination = directory.appendingPathComponent(name)
            do {
                try current.writeBackup(to: destination, now: Self.sample().wall)
                backupNotice = "保存しました：\(name)"
            } catch {
                backupNotice = "保存できませんでした。保存先の所有者・権限、空き容量、勤務記録を確認してください。"
            }
        }

        func start(targetMinutes: Int, restMinutes: Int) {
            do {
                let defaults = try NextDaySettings(targetMinutes: targetMinutes, restMinutes: restMinutes)
                perform(.clockIn(id: UUID(), profile: defaults.profile))
            } catch {
                message = "勤務設定を確認してください。"
            }
        }

        func perform(_ command: WorkdayCommand) {
            cancelReview()
            guard var current = controller else { return }
            do {
                glance = try current.perform(command, sample: Self.sample())
                controller = current
                queueReminders(force: true)
            } catch {
                fail(error)
            }
        }

        func prepareReview(selection: ObservationGap, classification: ReviewClassification) {
            guard var current = controller else { return }
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
            guard var current = controller else {
                queueReminders()
                return
            }
            do {
                let previousGoal = glance?.forecast.goal
                glance = try current.refresh(sample: Self.sample())
                controller = current
                queueReminders(force: previousGoal != glance?.forecast.goal)
                if let proposal = reviewProposal, !current.isCurrent(proposal) {
                    invalidateReview()
                }
            } catch {
                fail(error)
            }
        }

        private func fail(_ error: Error) {
            cancelReview()
            controller = nil
            glance = nil
            ready = false
            if error is ApplicationClockError {
                reminderClockUntrusted = true
                queueReminders(force: true)
            }
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
                message = "記録を停止：\(error)。時刻・データを確認して再読込してください。"
            }
        }

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

        func disableReminders() {
            guard sessionLock != nil, !requestingReminderPermission else { return }
            remindersEnabled = false
            UserDefaults.standard.set(false, forKey: "departureReminderEnabled")
            reminderStatus = "通知予約の取消を確認中"
            queueReminders(force: true)
        }

        private func latestReminderState() throws -> ReminderSyncState? {
            guard remindersEnabled, !reminderClockUntrusted else { return nil }
            guard ready, let controller else { throw ReminderDeliveryError.invalidRequest }
            do {
                return try controller.reminderState(sample: Self.sample())
            } catch is ApplicationClockError {
                return nil
            }
        }

        private func queueReminders(force: Bool = false) {
            if force {
                nextReminderCheck = 0
            }
            guard let reminderCoordinator, sessionLock != nil, !reminderRunning,
                  ready || reminderClockUntrusted || !remindersEnabled else { return }
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
                    reminderStatus = reminderClockUntrusted ? "時計異常のため通知停止" : "通知予約の更新完了（配信はOS依存）"
                } else {
                    reminderStatus = "通知は無効です。"
                }
            case .permissionUnavailable:
                reminderStatus = "macOSの通知設定を確認してください。"
            case .busy, .superseded, .cancellationPending:
                reminderStatus = "通知予約を再確認します。"
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
#endif
