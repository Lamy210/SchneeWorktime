#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    /// Acknowledging an uncertain interval is an explicit user assertion,
    /// never a clock-derived claim about what happened during a sleep gap.
    @MainActor
    struct SchemaTwoReviewableGapsView: View {
        @ObservedObject var model: DesktopModel
        let glance: WorktimeGlance
        @State private var selectedIndex = 0

        var body: some View {
            DisclosureGroup("要確認区間を訂正（schema-2）") {
                Text("未観測時間を自動で勤務扱いにはしません。選択した範囲だけ訂正し、元の記録と訂正履歴を残します。")
                    .font(.caption)
                Picker("要確認区間", selection: $selectedIndex) {
                    ForEach(Array(glance.reviewableGaps.enumerated()), id: \.offset) { index, gap in
                        Text("\(time(gap.start))〜\(time(gap.end))").tag(index)
                    }
                }
                if glance.reviewableGaps.indices.contains(selectedIndex) {
                    let gap = glance.reviewableGaps[selectedIndex]
                    SchemaTwoGapReviewEditor(model: model, glance: glance, gap: gap)
                        .id("\(glance.day.id)-\(glance.day.revision)-\(gap.start)-\(gap.end)")
                }
            }
            .disabled(!model.schemaTwoReviewEnabled)
            .onChange(of: glance.reviewableGaps) { _, _ in selectedIndex = 0 }
        }

        private func time(_ value: Int64) -> String {
            Date(timeIntervalSince1970: Double(value))
                .formatted(.dateTime.month().day().hour().minute().second())
        }
    }

    @MainActor
    private struct SchemaTwoGapReviewEditor: View {
        @ObservedObject var model: DesktopModel
        let glance: WorktimeGlance
        let gap: ObservationGap
        @State private var startOffset = "0"
        @State private var endOffset: String
        @State private var proposal: JournalV2WorktimeCorrectionProposal?
        @State private var expected: JournalV2WorkActionContext?
        @State private var category: ReviewClassification?
        @State private var confirmedSelection: ObservationGap?
        @State private var notice: String?

        init(model: DesktopModel, glance: WorktimeGlance, gap: ObservationGap) {
            self.model = model
            self.glance = glance
            self.gap = gap
            _endOffset = State(initialValue: String(ReviewRangeSelection.duration(of: gap) ?? 0))
        }

        private var selection: ObservationGap? {
            guard let start = Int64(startOffset), let end = Int64(endOffset) else { return nil }
            return try? ReviewRangeSelection.selection(
                in: gap, startOffset: start, endOffset: end
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                Text("区間先頭からの秒数を入力します。")
                    .font(.caption)
                HStack {
                    TextField("開始秒", text: $startOffset)
                    TextField("終了秒", text: $endOffset)
                }
                Button("区間全体を選択") {
                    startOffset = "0"
                    endOffset = String(ReviewRangeSelection.duration(of: gap) ?? 0)
                }
                if let selection {
                    Text("選択：\(time(selection.start))〜\(time(selection.end))")
                        .font(.caption)
                    categoryButtons(selection)
                } else {
                    Text("開始秒より終了秒を大きくし、区間内に収めてください。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let proposal {
                    confirmation(proposal)
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            .onChange(of: startOffset) { _, _ in reset() }
            .onChange(of: endOffset) { _, _ in reset() }
            .onChange(of: model.schemaTwoActionContext) { _, newer in
                if let expected, newer?.permitsRoutineObservation(since: expected) != true {
                    notice = "保存状態が更新されました。入力範囲と分類を保持しています。"
                }
            }
        }

        private func categoryButtons(_ chosen: ObservationGap) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("実際の状態を利用者が選択します。勤務としての計上は明示的な確認が必要です。")
                    .font(.caption)
                HStack {
                    Button("勤務") { prepare(.work, selection: chosen) }
                    Button("休憩") { prepare(.rest, selection: chosen) }
                    Button("非勤務") { prepare(.gap, selection: chosen) }
                }
            }
        }

        private func confirmation(_ value: JournalV2WorktimeCorrectionProposal) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Divider()
                Text("保存前の訂正案").font(.headline)
                Text("分類：\(categoryLabel(category))")
                Text("実働：\(worked(value.before)) → \(worked(value.after))")
                    .font(.caption)
                Text("記録済み休憩：\(value.before.snapshot.recordedRest)秒 → \(value.after.snapshot.recordedRest)秒")
                    .font(.caption)
                Text("確認時点の実働です。正常観測で合計は増えますが、訂正する範囲と分類は変わりません。")
                    .font(.caption)
                Text("訂正案は確定まで保存されません。")
                    .font(.caption)
                if let expected, model.schemaTwoActionContext?.permitsRoutineObservation(since: expected) != true {
                    Button("最新状態で訂正案を再確認") {
                        if let category, let selection {
                            prepare(category, selection: selection)
                        }
                    }
                } else {
                    Button("この区間の訂正を確定して保存") { commit(value) }
                        .disabled(expected == nil || selection != confirmedSelection)
                }
                Button("訂正案を破棄") { reset() }
            }
        }

        private func prepare(_ selected: ReviewClassification, selection: ObservationGap) {
            reset()
            notice = nil
            guard let context = model.schemaTwoActionContext,
                  context.day == glance.day
            else {
                notice = "勤務日の表示が変化しました。再表示してください。"
                return
            }
            do {
                let value = try model.previewSchemaTwoReview(
                    source: gap, selection: selection, classification: selected, matching: context
                )
                proposal = value
                expected = context
                category = selected
                confirmedSelection = selection
            } catch {
                notice = "訂正案を作成できません。最新の勤務記録と範囲を確認してください。"
            }
        }

        private func commit(_ value: JournalV2WorktimeCorrectionProposal) {
            guard let context = expected, let confirmedSelection, selection == confirmedSelection,
                  model.schemaTwoActionContext?.permitsRoutineObservation(since: context) == true
            else {
                notice = "保存せず最新状態で再確認してください。"
                return
            }
            reset()
            do {
                try model.commitSchemaTwoReview(value, matching: context)
                notice = "訂正履歴と変更後の区間を保存しました。"
            } catch JournalV2WorktimeCorrectionError.staleProposal {
                notice = "訂正の条件が変化しました。入力範囲を保持しています。最新状態で再確認してください。"
            } catch {
                notice = "保存の確定を確認できません。自動再試行せず原本を確認してください。"
            }
        }

        private func reset() {
            proposal = nil
            expected = nil
            category = nil
            confirmedSelection = nil
        }

        private func worked(_ glance: WorktimeGlance) -> String {
            let bounds = glance.snapshot.bounds
            return bounds.lower == bounds.upper
                ? "\(bounds.lower)秒"
                : "\(bounds.lower)〜\(bounds.upper)秒"
        }

        private func categoryLabel(_ value: ReviewClassification?) -> String {
            switch value {
            case .work: "勤務"
            case .rest: "休憩"
            case .gap: "非勤務"
            case nil: "未選択"
            }
        }

        private func time(_ value: Int64) -> String {
            Date(timeIntervalSince1970: Double(value))
                .formatted(.dateTime.month().day().hour().minute().second())
        }
    }
#endif
