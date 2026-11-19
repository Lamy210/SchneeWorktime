#if os(macOS)
    import WorktimeApplication
    import WorktimeDomain

    extension DesktopModel {
        func previewDesiredDeparture(at instant: Int64) throws -> DesiredDepartureProposal {
            guard ready, !choosingBackupDestination, reviewProposal == nil, let controller else {
                throw DesiredDepartureSaveError.staleProposal
            }
            return try controller.previewDesiredDeparture(at: instant, sample: Self.sample())
        }

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

        func previewClockOutCorrection(
            day: Workday, oldEnd: Int64, newEnd: Int64, historical: HistoricalReviewContext? = nil
        ) throws -> WorktimeClockOutProposal {
            guard ready, !choosingBackupDestination, reviewProposal == nil, let controller else {
                throw ClockOutInteractionError.staleProposal
            }
            return try controller.previewClockOutCorrection(
                expectedDay: day, oldEnd: oldEnd, newEnd: newEnd, historical: historical, sample: Self.sample()
            )
        }

        func previewRestBoundaryCorrection(
            day: Workday, old: Int64, new: Int64, boundary: RestBoundary,
            historical: HistoricalReviewContext? = nil
        ) throws -> WorktimeRestEndProposal {
            guard ready, !choosingBackupDestination, reviewProposal == nil, let controller else {
                throw RestEndInteractionError.staleProposal
            }
            return try controller.previewRestBoundaryCorrection(
                expectedDay: day, old: old, new: new, boundary: boundary,
                historical: historical, sample: Self.sample()
            )
        }
    }
#endif
