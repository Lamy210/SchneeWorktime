#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct ReviewRangeSettingsView: View {
        @ObservedObject var model: DesktopModel
        let glance: WorktimeGlance
        var historical: HistoricalReviewContext?
        @State private var selectedIndex = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("要確認区間（残り\(glance.reviewableGaps.count)件）").font(.headline)
                Picker("訂正する区間", selection: $selectedIndex) {
                    ForEach(Array(glance.reviewableGaps.enumerated()), id: \.offset) { index, gap in
                        Text("\(reviewRangeTime(gap.start))〜\(reviewRangeTime(gap.end))").tag(index)
                    }
                }
                if glance.reviewableGaps.indices.contains(selectedIndex) {
                    let gap = glance.reviewableGaps[selectedIndex]
                    if let duration = ReviewRangeSelection.duration(of: gap) {
                        ReviewRangeEditor(
                            model: model, day: glance.day, gap: gap, duration: duration, historical: historical
                        )
                        .id("\(glance.day.id)-\(glance.day.revision)-\(gap.start)-\(gap.end)")
                    }
                }
            }
            .disabled(!model.ready || model.choosingBackupDestination)
            .onChange(of: glance.reviewableGaps) { _, _ in selectedIndex = 0 }
        }
    }

    @MainActor
    private struct ReviewRangeEditor: View {
        @ObservedObject var model: DesktopModel
        let day: Workday
        let gap: ObservationGap
        let duration: Int64
        let historical: HistoricalReviewContext?
        @State private var startOffset = "0"
        @State private var endOffset: String

        init(
            model: DesktopModel, day: Workday, gap: ObservationGap, duration: Int64,
            historical: HistoricalReviewContext?
        ) {
            self.model = model
            self.day = day
            self.gap = gap
            self.duration = duration
            self.historical = historical
            _endOffset = State(initialValue: String(duration))
        }

        private var selection: ObservationGap? {
            guard let start = Int64(startOffset), let end = Int64(endOffset) else { return nil }
            return try? ReviewRangeSelection.selection(in: gap, startOffset: start, endOffset: end)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("区間開始からの秒数（0〜\(duration)秒）で範囲を指定します。")
                    .font(.caption)
                TextField("開始オフセット（秒）", text: $startOffset)
                TextField("終了オフセット（秒）", text: $endOffset)
                Button("区間全体を選択") {
                    startOffset = "0"
                    endOffset = String(duration)
                }
                if let selection {
                    Text("選択：\(reviewRangeTime(selection.start))〜\(reviewRangeTime(selection.end))")
                        .font(.caption)
                    Text("選択範囲以外の要確認区間は残ります。保存前に訂正案を確認してください。")
                        .font(.caption)
                    Button("勤務継続として確認") { prepare(selection, as: .work) }
                    Button("休憩として訂正") { prepare(selection, as: .rest) }
                    Button("非勤務として訂正") { prepare(selection, as: .gap) }
                } else {
                    Text("開始より終了が後で、選択区間内に収まる秒数を入力してください。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }

        private func prepare(_ selection: ObservationGap, as classification: ReviewClassification) {
            model.prepareReview(
                selection: selection, classification: classification, expectedDay: day, source: gap,
                historical: historical
            )
        }
    }

    private func reviewRangeTime(_ instant: Int64) -> String {
        Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute().second())
    }
#endif
