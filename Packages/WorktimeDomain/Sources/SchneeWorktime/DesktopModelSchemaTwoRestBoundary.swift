#if os(macOS)
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        func previewSchemaTwoRestBoundary(
            _ intent: JournalV2RestBoundaryIntent, day: Workday,
            historical: HistoricalReviewContext? = nil
        ) throws -> JournalV2ConfirmedRestBoundary {
            guard schemaTwoReviewEnabled, let current = schemaTwoWorkSession else {
                throw JournalV2WorktimeCorrectionError.staleProposal
            }
            return try current.previewConfirmedRestBoundary(
                intent, day: day, historical: historical,
                matching: current.workActionContext, sample: Self.sample()
            )
        }

        func commitSchemaTwoRestBoundary(_ proposal: JournalV2ConfirmedRestBoundary) throws {
            guard schemaTwoReviewEnabled, var current = schemaTwoWorkSession else {
                throw JournalV2WorktimeCorrectionError.staleProposal
            }
            do {
                let updated = try current.commitConfirmedRestBoundary(proposal, sample: Self.sample())
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
                queueReminders(force: true)
            } catch let error as JournalV2WorktimeCorrectionError {
                throw error
            } catch let error as RestEndCorrectionError {
                throw error
            } catch {
                schemaTwoSessionFailed(error)
                throw error
            }
        }
    }
#endif
