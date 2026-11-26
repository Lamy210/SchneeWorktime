#if os(macOS)
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        func previewSchemaTwoClockBoundary(
            _ intent: JournalV2ClockBoundaryIntent, day: Workday,
            historical: HistoricalReviewContext? = nil
        ) throws -> JournalV2ConfirmedClockBoundary {
            guard schemaTwoReviewEnabled, let current = schemaTwoWorkSession else {
                throw JournalV2WorktimeCorrectionError.staleProposal
            }
            return try current.previewConfirmedClockBoundary(
                intent, day: day, historical: historical,
                matching: current.workActionContext, sample: Self.sample()
            )
        }

        func commitSchemaTwoClockBoundary(_ proposal: JournalV2ConfirmedClockBoundary) throws {
            guard schemaTwoReviewEnabled, var current = schemaTwoWorkSession else {
                throw JournalV2WorktimeCorrectionError.staleProposal
            }
            do {
                let updated = try current.commitConfirmedClockBoundary(proposal, sample: Self.sample())
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
                queueReminders(force: true)
            } catch let error as JournalV2WorktimeCorrectionError {
                throw error
            } catch let error as ClockInCorrectionError {
                throw error
            } catch let error as ClockOutCorrectionError {
                throw error
            } catch {
                schemaTwoSessionFailed(error)
                throw error
            }
        }
    }
#endif
