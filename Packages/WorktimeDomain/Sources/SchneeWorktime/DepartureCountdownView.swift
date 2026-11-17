#if os(macOS)
    import SwiftUI
    import WorktimeApplication

    struct DepartureCountdownView: View {
        let countdown: DepartureCountdown

        var body: some View {
            if case let .projected(earliest, departure) = countdown {
                VStack(alignment: .leading, spacing: 4) {
                    Text("休憩込み退勤見込みまで").font(.caption)
                    Text(DepartureCountdown.duration(departure))
                        .font(.system(.title, design: .rounded).monospacedDigit())
                        .accessibilityLabel("休憩込み退勤見込みまで")
                        .accessibilityValue(DepartureCountdown.duration(departure))
                    Text("最短目標達成まで：\(DepartureCountdown.duration(earliest))")
                        .font(.caption)
                        .monospacedDigit()
                    Text("予測値です。退勤実績ではありません。").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
#endif
