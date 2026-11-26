#if os(macOS)
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        var schemaTwoRetrospectiveStartEnabled: Bool {
            guard let context = schemaTwoActionContext else { return false }
            return !ready && controller == nil && sessionLock != nil &&
                !schemaTwoWorkBusy && !maintenanceInProgress &&
                !choosingBackupDestination && context.canOpenWorkday &&
                (context.day == nil || context.day?.state == .ended)
        }

        func previewSchemaTwoRetrospectiveStart(
            at instant: Int64, profile: WorkdayProfile, matching expected: JournalV2WorkActionContext
        ) throws -> RetrospectiveStartProposal {
            guard schemaTwoRetrospectiveStartEnabled, let current = schemaTwoWorkSession
            else { throw RetrospectiveStartError.staleProposal }
            do {
                return try current.previewConfirmedRetrospectiveStart(
                    at: instant, profile: profile, matching: expected, sample: Self.sample()
                )
            } catch let error as RetrospectiveStartError {
                throw error
            } catch {
                schemaTwoSessionFailed(error)
                throw error
            }
        }

        func commitSchemaTwoRetrospectiveStart(
            _ proposal: RetrospectiveStartProposal, profile: WorkdayProfile,
            matching expected: JournalV2WorkActionContext
        ) throws {
            guard schemaTwoRetrospectiveStartEnabled, var current = schemaTwoWorkSession
            else { throw RetrospectiveStartError.staleProposal }
            do {
                let updated = try current.commitConfirmedRetrospectiveStart(
                    proposal, profile: profile, matching: expected, sample: Self.sample()
                )
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
                queueReminders(force: true)
            } catch let error as RetrospectiveStartError {
                throw error
            } catch {
                // Never retry a potentially committed start.
                schemaTwoSessionFailed(error)
                throw error
            }
        }
    }
#endif
