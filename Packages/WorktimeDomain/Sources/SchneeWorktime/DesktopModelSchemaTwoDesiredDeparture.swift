#if os(macOS)
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    /// Schema-2 intention editing is intentionally isolated from legacy schema-1.
    /// Preview is read-only; only a matching, explicitly confirmed proposal writes.
    extension DesktopModel {
        var schemaTwoDesiredDepartureEnabled: Bool {
            guard let context = schemaTwoActionContext else { return false }
            return !ready && controller == nil && sessionLock != nil &&
                !schemaTwoWorkBusy && !maintenanceInProgress &&
                !choosingBackupDestination && context.canAppend &&
                context.day?.state != .ended
        }

        func previewSchemaTwoDesiredDeparture(
            at instant: Int64, matching expected: JournalV2WorkActionContext
        ) throws -> JournalV2DesiredDepartureProposal {
            guard schemaTwoDesiredDepartureEnabled, let current = schemaTwoWorkSession,
                  expected == current.workActionContext
            else { throw DesiredDepartureSaveError.staleProposal }
            do {
                return try current.previewDesiredDeparture(at: instant, sample: Self.sample())
            } catch let error as DesiredDepartureSaveError {
                throw error
            } catch {
                schemaTwoSessionFailed(error)
                throw error
            }
        }

        func confirmSchemaTwoDesiredDeparture(
            _ proposal: JournalV2DesiredDepartureProposal,
            matching expected: JournalV2WorkActionContext,
            warningAcknowledged: Bool
        ) throws {
            guard schemaTwoDesiredDepartureEnabled, var current = schemaTwoWorkSession,
                  current.workActionContext.permitsRoutineObservation(since: expected),
                  current.isCurrent(proposal)
            else { throw DesiredDepartureSaveError.staleProposal }
            do {
                let updated = try current.commitConfirmedDesiredDeparture(
                    proposal, matching: expected, warningAcknowledged: warningAcknowledged, sample: Self.sample()
                )
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
                queueReminders(force: true)
            } catch let error as DesiredDepartureSaveError {
                throw error
            } catch {
                // A committed event followed by a checkpoint error is ambiguous.
                // Discard the in-memory session; never submit the same intention again.
                schemaTwoSessionFailed(error)
                throw error
            }
        }

        func clearSchemaTwoDesiredDeparture(matching expected: JournalV2WorkActionContext) throws {
            guard schemaTwoDesiredDepartureEnabled, var current = schemaTwoWorkSession,
                  current.workActionContext.permitsRoutineObservation(since: expected), let day = expected.day,
                  schemaTwoWorkGlance?.day == day,
                  schemaTwoWorkGlance?.desiredDepartureAt != nil
            else { throw DesiredDepartureSaveError.staleProposal }
            do {
                let updated = try current.clearConfirmedDesiredDeparture(matching: expected, sample: Self.sample())
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
                queueReminders(force: true)
            } catch let error as DesiredDepartureSaveError {
                throw error
            } catch {
                schemaTwoSessionFailed(error)
                throw error
            }
        }
    }
#endif
