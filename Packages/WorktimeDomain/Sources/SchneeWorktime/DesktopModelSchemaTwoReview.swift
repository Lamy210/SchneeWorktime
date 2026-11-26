#if os(macOS)
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        var schemaTwoReviewEnabled: Bool {
            guard let current = schemaTwoWorkSession,
                  schemaTwoWorkGlance != nil else { return false }
            return !ready && controller == nil && sessionLock != nil &&
                !schemaTwoWorkBusy && !maintenanceInProgress &&
                !choosingBackupDestination && current.workActionContext.canAppend
        }

        /// Only the most recently displayed day is editable in this first UI.
        /// Historical edits require their own history/version selection flow.
        func previewSchemaTwoReview(
            source: ObservationGap, selection: ObservationGap,
            classification: ReviewClassification,
            matching expected: JournalV2WorkActionContext
        ) throws -> JournalV2WorktimeCorrectionProposal {
            guard schemaTwoReviewEnabled, let current = schemaTwoWorkSession,
                  expected == current.workActionContext,
                  schemaTwoWorkGlance?.day == expected.day
            else { throw JournalV2WorktimeCorrectionError.staleProposal }
            do {
                return try current.previewConfirmedReview(
                    source: source, selection: selection, classification: classification,
                    matching: expected, sample: Self.sample()
                )
            } catch is JournalV2WorktimeCorrectionError {
                throw JournalV2WorktimeCorrectionError.staleProposal
            } catch is JournalV2WorkActionError {
                throw JournalV2WorkActionError.insufficientCapacity
            } catch {
                schemaTwoSessionFailed(error)
                throw error
            }
        }

        func commitSchemaTwoReview(
            _ proposal: JournalV2WorktimeCorrectionProposal,
            matching expected: JournalV2WorkActionContext
        ) throws {
            guard schemaTwoReviewEnabled, var current = schemaTwoWorkSession,
                  expected == current.workActionContext,
                  proposal.before.day == schemaTwoWorkGlance?.day
            else { throw JournalV2WorktimeCorrectionError.staleProposal }
            do {
                let updated = try current.commitConfirmedReview(
                    proposal, matching: expected, sample: Self.sample()
                )
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
                queueReminders(force: true)
            } catch is JournalV2WorktimeCorrectionError {
                throw JournalV2WorktimeCorrectionError.staleProposal
            } catch is JournalV2WorkActionError {
                throw JournalV2WorkActionError.insufficientCapacity
            } catch {
                // A committed audit event followed by a checkpoint failure is
                // ambiguous. Discard the session; never retry the same edit.
                schemaTwoSessionFailed(error)
                throw error
            }
        }
    }
#endif
