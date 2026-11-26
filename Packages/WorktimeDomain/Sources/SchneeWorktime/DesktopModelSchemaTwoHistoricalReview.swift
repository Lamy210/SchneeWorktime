#if os(macOS)
    import Foundation
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        func schemaTwoHistory(offset: Int = 0, previous: WorktimeHistory? = nil) throws -> WorktimeHistory {
            guard schemaTwoReviewEnabled, let current = schemaTwoWorkSession else {
                throw HistoricalReviewError.staleContext
            }
            return try current.recentHistory(now: Self.sample().wall, offset: offset, previous: previous)
        }

        func selectSchemaTwoHistoricalDay(
            id: UUID, history: WorktimeHistory
        ) throws -> HistoricalReviewContext {
            guard schemaTwoReviewEnabled, let current = schemaTwoWorkSession else {
                throw HistoricalReviewError.staleContext
            }
            return try current.historicalReviewContext(dayID: id, history: history, sample: Self.sample())
        }

        func previewSchemaTwoHistoricalGap(
            historical: HistoricalReviewContext, source: ObservationGap, selection: ObservationGap,
            classification: ReviewClassification
        ) throws -> JournalV2HistoricalGapProposal {
            guard schemaTwoReviewEnabled, let current = schemaTwoWorkSession else {
                throw JournalV2WorktimeCorrectionError.staleProposal
            }
            return try current.previewHistoricalGap(
                historical: historical, source: source, selection: selection,
                classification: classification, sample: Self.sample()
            )
        }

        func commitSchemaTwoHistoricalGap(_ proposal: JournalV2HistoricalGapProposal) throws {
            guard schemaTwoReviewEnabled, var current = schemaTwoWorkSession else {
                throw JournalV2WorktimeCorrectionError.staleProposal
            }
            do {
                let updated = try current.commitHistoricalGap(proposal, sample: Self.sample())
                schemaTwoWorkSession = current
                schemaTwoWorkGlance = updated
                schemaTwoWorkNotice = nil
                queueReminders(force: true)
            } catch let error as JournalV2WorktimeCorrectionError {
                throw error
            } catch {
                schemaTwoSessionFailed(error)
                throw error
            }
        }
    }
#endif
