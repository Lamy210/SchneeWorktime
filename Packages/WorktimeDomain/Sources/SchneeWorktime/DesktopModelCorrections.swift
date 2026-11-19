#if os(macOS)
    import WorktimeApplication

    extension DesktopModel {
        func confirmRestBoundaryCorrection(_ proposal: WorktimeRestEndProposal) throws {
            try confirmBoundaryCorrection(
                stale: RestEndInteractionError.staleProposal, isCurrent: { $0.isCurrent(proposal) },
                commit: { current in
                    try current.commitRestBoundaryCorrection(proposal, sample: Self.sample())
                }
            )
        }

        func confirmClockOutCorrection(_ proposal: WorktimeClockOutProposal) throws {
            try confirmBoundaryCorrection(
                stale: ClockOutInteractionError.staleProposal, isCurrent: { $0.isCurrent(proposal) },
                commit: { current in
                    try current.commitClockOutCorrection(proposal, sample: Self.sample())
                }
            )
        }

        func confirmRetrospectiveStart(_ proposal: RetrospectiveStartProposal) throws {
            let stale = RetrospectiveStartError.staleProposal
            try confirmBoundaryCorrection(
                stale: stale, isCurrent: { _ in true },
                commit: { current in
                    try current.commitRetrospectiveStart(proposal, sample: Self.sample())
                }
            )
        }
    }
#endif
