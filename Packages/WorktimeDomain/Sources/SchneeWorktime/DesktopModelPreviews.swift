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

        func previewRestEndCorrection(
            day: Workday, oldEnd: Int64, newEnd: Int64
        ) throws -> WorktimeRestEndProposal {
            guard ready, !choosingBackupDestination, reviewProposal == nil,
                  glance?.day == day, let controller
            else { throw RestEndInteractionError.staleProposal }
            return try controller.previewRestEndCorrection(
                expectedDay: day, oldEnd: oldEnd, newEnd: newEnd, sample: Self.sample()
            )
        }
    }
#endif
