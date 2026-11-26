#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct SchemaTwoHistoricalReviewView: View {
        @ObservedObject var model: DesktopModel
        @State private var history: WorktimeHistory?
        @State private var historical: HistoricalReviewContext?
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("過去勤務日の訂正（schema-2）") {
                Text("終了済みの過去勤務日を選択します。最新勤務日の訂正は通常の勤務画面から行います。")
                    .font(.caption)
                Button("最新の履歴を読み込む") { reload() }
                if let history {
                    if model.schemaTwoWorkSession?.isCurrent(history) == true {
                        page(history)
                    } else {
                        Text("履歴が変わりました。再読込してください。").font(.caption)
                    }
                }
                if let historical, model.schemaTwoWorkSession?.isCurrent(historical) == true {
                    SchemaTwoHistoricalGapEditor(model: model, historical: historical, onSaved: didSave)
                        .id(historical.glance.day.id)
                    Button("選択解除") { self.historical = nil }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            .disabled(!model.schemaTwoReviewEnabled)
            .onChange(of: model.schemaTwoActionContext?.version) { _, _ in
                historical = nil
            }
        }

        private func didSave() {
            reload()
            notice = history == nil ? "訂正を保存しました。履歴の再読込が必要です。" : "訂正を保存し、最新履歴を読み込みました。"
        }

        private func page(_ page: WorktimeHistory) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let previous = page.previousOffset {
                        Button("新しい履歴") { reload(offset: previous, previous: page) }
                    }
                    Text("\(page.offset + page.rows.count) / \(page.totalEndedDays)").font(.caption)
                    if let next = page.nextOffset {
                        Button("古い履歴") { reload(offset: next, previous: page) }
                    }
                }
                ForEach(page.rows) { row in
                    if row.id != model.schemaTwoActionContext?.day?.id {
                        Button("\(label(row.startedAt)) の勤務日を選択") { select(row.id, page: page) }
                    }
                }
            }
        }

        private func reload(offset: Int = 0, previous: WorktimeHistory? = nil) {
            historical = nil
            history = nil
            notice = nil
            do {
                history = try model.schemaTwoHistory(offset: offset, previous: previous)
            } catch {
                notice = "履歴を読み込めません。最新状態を確認してください。"
            }
        }

        private func select(_ id: UUID, page: WorktimeHistory) {
            historical = nil
            notice = nil
            do {
                historical = try model.selectSchemaTwoHistoricalDay(id: id, history: page)
            } catch {
                notice = "過去勤務日を選択できません。履歴を再読込してください。"
            }
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.year().month().day().hour().minute())
        }
    }

    @MainActor
    private struct SchemaTwoHistoricalGapEditor: View {
        @ObservedObject var model: DesktopModel
        let historical: HistoricalReviewContext
        let onSaved: () -> Void
        @State private var index = 0
        @State private var start = "0"
        @State private var end = ""
        @State private var proposal: JournalV2HistoricalGapProposal?
        @State private var notice: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("過去勤務日の要確認区間").font(.headline)
                if historical.glance.reviewableGaps.isEmpty {
                    Text("要確認区間はありません。").font(.caption)
                } else {
                    Picker("要確認区間", selection: $index) {
                        ForEach(Array(historical.glance.reviewableGaps.enumerated()), id: \.offset) { gapIndex, gap in
                            Text("\(label(gap.start))〜\(label(gap.end))").tag(gapIndex)
                        }
                    }
                    if historical.glance.reviewableGaps.indices.contains(index) {
                        editor(historical.glance.reviewableGaps[index])
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            .onChange(of: index) { _, _ in reset() }
            .onChange(of: start) { _, _ in proposal = nil }
            .onChange(of: end) { _, _ in proposal = nil }
        }

        private func editor(_ gap: ObservationGap) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("区間先頭からの秒数で指定します。").font(.caption)
                HStack {
                    TextField("開始秒", text: $start)
                    TextField("終了秒", text: $end)
                }
                Button("全区間を選択") {
                    start = "0"
                    end = String(ReviewRangeSelection.duration(of: gap) ?? 0)
                }
                if let selection = selection(in: gap) {
                    HStack {
                        Button("勤務") { prepare(.work, gap: gap, selection: selection) }
                        Button("休憩") { prepare(.rest, gap: gap, selection: selection) }
                        Button("非勤務") { prepare(.gap, gap: gap, selection: selection) }
                    }
                }
                if let proposal {
                    confirmation(proposal, gap: gap)
                }
            }
        }

        private func selection(in gap: ObservationGap) -> ObservationGap? {
            guard let lower = Int64(start), let upper = Int64(end) else { return nil }
            return try? ReviewRangeSelection.selection(in: gap, startOffset: lower, endOffset: upper)
        }

        private func confirmation(_ value: JournalV2HistoricalGapProposal, gap: ObservationGap) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("選択：\(label(value.selection.start))〜\(label(value.selection.end))")
                Text("分類：\(category(value.classification))")
                Text("実働：\(worked(value.correction.before)) → \(worked(value.correction.after))")
                let before = value.correction.before.snapshot.recordedRest
                let after = value.correction.after.snapshot.recordedRest
                Text("休憩：\(before) → \(after)秒")
                Text("申告した区間だけ訂正し、監査履歴を保存します。").font(.caption)
                Button("訂正を確定") { commit(value, gap: gap) }
                    .disabled(model.schemaTwoWorkSession?.isCurrent(value) != true ||
                        selection(in: gap) != value.selection)
                Button("キャンセル") { proposal = nil }
            }
            .font(.caption)
        }

        private func prepare(_ classification: ReviewClassification, gap: ObservationGap, selection: ObservationGap) {
            proposal = nil
            notice = nil
            do {
                proposal = try model.previewSchemaTwoHistoricalGap(
                    historical: historical, source: gap, selection: selection, classification: classification
                )
            } catch {
                notice = "訂正案を作成できません。履歴と範囲を確認してください。"
            }
        }

        private func commit(_ value: JournalV2HistoricalGapProposal, gap: ObservationGap) {
            guard selection(in: gap) == value.selection else {
                proposal = nil
                return
            }
            proposal = nil
            do {
                try model.commitSchemaTwoHistoricalGap(value)
                onSaved()
            } catch {
                notice = "保存を確認できません。自動再試行せず、最新記録を確認してください。"
            }
        }

        private func reset() {
            start = "0"
            end = ""
            proposal = nil
            notice = nil
        }

        private func worked(_ glance: WorktimeGlance) -> String {
            "\(glance.snapshot.bounds.lower)〜\(glance.snapshot.bounds.upper)秒"
        }

        private func category(_ classification: ReviewClassification) -> String {
            switch classification {
            case .work: "勤務"
            case .rest: "休憩"
            case .gap: "非勤務"
            }
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute().second())
        }
    }
#endif
