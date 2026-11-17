#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct DepartureScenarioView: View {
        let glance: WorktimeGlance
        @State private var candidate = Date().addingTimeInterval(3600)
        @State private var returnDate = Date().addingTimeInterval(1800)
        @State private var includeReturn = false
        @State private var leaveNow = false

        var body: some View {
            DisclosureGroup("退勤時刻を試算") {
                Text("試算のみ。実績や退勤予定を保存しません。現在のタイムゾーンで表示します。")
                    .font(.caption)
                Toggle("今帰る場合", isOn: $leaveNow)
                if !leaveNow {
                    DatePicker("退勤候補", selection: $candidate, displayedComponents: [.date, .hourAndMinute])
                    if glance.day.state == .onBreak {
                        Toggle("復帰予定を仮定する", isOn: $includeReturn)
                        if includeReturn {
                            DatePicker("復帰予定", selection: $returnDate, displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                }
                if let scenario = scenario() {
                    resultView(scenario)
                } else {
                    Text("試算できない時刻です。")
                }
            }
        }

        private func scenario() -> DepartureScenario? {
            let instant = leaveNow ? glance.observedAt : seconds(candidate)
            guard let instant else { return nil }
            let returnAt = includeReturn && glance.day.state == .onBreak && !leaveNow ? seconds(returnDate) : nil
            return try? glance.departureScenario(candidate: instant, returnAt: returnAt)
        }

        @ViewBuilder
        private func resultView(_ scenario: DepartureScenario) -> some View {
            switch scenario.result {
            case let .feasible(worked, futureRest):
                Text("見込み実働：\(rangeLabel(worked))")
                Text("今後の仮定休憩：\(futureRest / 60)分\(futureRest % 60)秒")
                if let remaining = scenario.remaining, let surplus = scenario.surplus {
                    Text("日次目標まで：\(rangeLabel(remaining))")
                    Text("日次目標超過：\(rangeLabel(surplus))")
                }
            case .infeasible:
                Text("この時刻では予定休憩・復帰条件が成立しません。")
            case .unknown:
                Text("復帰時刻を仮定すると未来の試算ができます。")
            case .invalidCandidate:
                Text("退勤候補が過去です。日時を変更してください。")
            case .ended:
                Text("退勤済みの勤務日は試算できません。")
            }
        }

        private func rangeLabel(_ range: ClosedRange<Int64>) -> String {
            let lower = "\(range.lowerBound / 60)分\(range.lowerBound % 60)秒"
            let upper = "\(range.upperBound / 60)分\(range.upperBound % 60)秒"
            return range.lowerBound == range.upperBound ? lower : "\(lower)〜\(upper)"
        }

        private func seconds(_ date: Date) -> Int64? {
            Int64(exactly: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        }
    }
#endif
