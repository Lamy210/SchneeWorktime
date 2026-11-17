#if os(macOS)
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct BreakRecordAdvisoryView: View {
        let glance: WorktimeGlance

        var body: some View {
            let advisory = BreakRecordAdvisory.assess(snapshot: glance.snapshot, profile: glance.day.profile)
            if advisory != .none {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        advisory == .review ? "休憩記録を確認してください" : "休憩記録が不足している可能性があります",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    Text("記録済み休憩：\(DepartureCountdown.duration(glance.snapshot.recordedRest))")
                    Text("実績と勤務先の適用ルールを確認してください。法的適否の判定ではありません。")
                }
                .font(.caption)
            }
        }
    }
#endif
