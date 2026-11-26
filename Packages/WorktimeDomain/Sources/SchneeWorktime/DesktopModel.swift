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
        @Published var schemaTwoInspection: JournalV2ReadOnlyInspection?
        @Published var schemaTwoWorkGlance: WorktimeGlance? {
            didSet { updateObservationTimer() }
        }

        @Published var schemaTwoWorkNotice: String?
        @Published var schemaTwoWorkBusy = false
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
        @Published var schemaTwoResetNotice: String?

        @Published var remindersEnabled = UserDefaults.standard.bool(forKey: "departureReminderEnabled")
        @Published var departureLeads = ReminderLeadSettings.decode(
            UserDefaults.standard.string(forKey: "departureReminderLeads")
        )
        @Published var earliestReminderEnabled = UserDefaults.standard.bool(
            forKey: "earliestReminderEnabled"
        )
        @Published var referenceReminderEnabled = UserDefaults.standard.bool(
            forKey: "referenceReminderEnabled"
        )
        @Published var reminderStatus = ""
        @Published var requestingReminderPermission = false

        private(set) var controller: WorktimeController?
        var schemaTwoWorkSession: JournalV2WorktimeController?
        var sessionLock: LocalSessionLock?
        private(set) var reminderCoordinator: DesktopReminderCoordinator?
        var reminderRunning = false
        var nextReminderCheck: Double = 0
        var reminderStateUntrusted = false
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
            let cadence = ObservationCadence(dayState: schemaTwoWorkGlance?.day.state ?? glance?.day.state)
            observationTimer.update(to: cadence) { [weak self] in
                self?.tick()
            }
        }

        func open(create: Bool) {
            guard !maintenanceInProgress, !choosingBackupDestination, !schemaTwoWorkBusy else { return }
            schemaTwoWorkSession = nil
            schemaTwoWorkGlance = nil
            schemaTwoWorkNotice = nil
            rollbackProposal = nil
            resetState.proposal = nil
            cancelReview()
            controller = nil
            ready = false
            glance = nil
            schemaTwoInspection = nil
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
                if let reason = try schemaTwoStartupBlockReason(url: url, create: create) {
                    let decision = try DesktopStorageLaunchGuard.decide(
                        url: url, createIfMissing: false, allowLegacyDevelopment: false
                    )
                    if decision == .schemaTwoAwaitingUI {
                        schemaTwoInspection = try JournalV2ReadOnlyInspection(url: url, now: sample.wall)
                    }
                    message = reason
                    reminderStateUntrusted = true
                    queueReminders(force: true)
                    return
                }
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
            schemaTwoInspection = nil
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
                canOpenWorkday: controller?.journalCapacity.canOpenWorkday == true,
                canChangeBreak: allowsOptionalJournalMutation,
                canClockOut: (controller?.journalCapacity.remainingEvents ?? 0) > 0
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
            if schemaTwoWorkSession != nil {
                refreshSchemaTwoWorkSession()
                return
            }
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
            schemaTwoWorkSession = nil
            schemaTwoWorkGlance = nil
            schemaTwoInspection = nil
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
            } catch let error as ClockInInteractionError {
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
