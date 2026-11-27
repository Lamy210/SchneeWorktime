#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct SchemaTwoRestBoundaryView: View {
        @ObservedObject var model: DesktopModel
        let day: Workday
        let boundary: RestBoundary
        var historical: HistoricalReviewContext?
        var onSaved: (() -> Void)? = nil
        @State private var selected: Int64?
        @State private var minutes = ""
        @State private var proposal: JournalV2ConfirmedRestBoundary?
        @State private var notice: String?

        private var boundaryName: String {
            boundary == .start ? "休憩開始" : "休憩終了"
        }

        private var boundaries: [Int64] {
            let leftKind: IntervalKind = boundary == .start ? .work : .rest
            let rightKind: IntervalKind = boundary == .start ? .rest : .work
            return zip(day.intervals, day.intervals.dropFirst()).compactMap { left, right in
                guard left.kind == leftKind, right.kind == rightKind, left.end == right.start else { return nil }
                return left.end
            }
        }

        private var intent: JournalV2RestBoundaryIntent? {
            guard let selected, boundaries.contains(selected), let offset = Int64(minutes),
                  offset != 0, (-1440 ... 1440).contains(offset)
            else { return nil }
            let (new, overflow) = selected.addingReportingOverflow(offset * 60)
            guard !overflow else { return nil }
            return JournalV2RestBoundaryIntent(boundary: boundary, old: selected, new: new)
        }

        var body: some View {
            if !boundaries.isEmpty {
                DisclosureGroup("記録済み\(boundaryName)の訂正（schema-2）") {
                    Picker("元の\(boundaryName)", selection: $selected) {
                        Text("選択してください").tag(nil as Int64?)
                        ForEach(boundaries, id: \.self) { value in
                            Text(label(value)).tag(Optional(value))
                        }
                    }
                    TextField("変更分（分、前倒しは負数）", text: $minutes)
                    Text("±1440分以内。元の秒は維持し、隣接する区間だけ変更します。")
                        .font(.caption)
                    Button("訂正案を確認") { prepare() }
                        .disabled(intent == nil)
                    if let proposal {
                        confirmation(proposal)
                    }
                    if let notice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                    }
                }
                .disabled(!model.schemaTwoReviewEnabled)
                .onChange(of: selected) { _, _ in proposal = nil }
                .onChange(of: minutes) { _, _ in proposal = nil }
                .onChange(of: day) { _, _ in
                    proposal = nil
                    if let selected, !boundaries.contains(selected) {
                        self.selected = nil
                    }
                }
            }
        }

        private func confirmation(_ value: JournalV2ConfirmedRestBoundary) -> some View {
            let before = value.correction.before
            let after = value.correction.after
            let current = model.schemaTwoWorkSession?.isCurrent(value) == true && intent == value.intent
            return VStack(alignment: .leading, spacing: 5) {
                Text("訂正案（未保存）").font(.headline)
                Text("\(boundaryName)：\(label(value.intent.old)) → \(label(value.intent.new))")
                Text("実働：\(worked(before)) → \(worked(after))")
                Text("記録済み休憩：\(before.snapshot.recordedRest) → \(after.snapshot.recordedRest)秒")
                Text("退勤見込み：\(forecast(before)) → \(forecast(after))")
                Text("確認時点の合計です。通常観測中も訂正範囲と実績の増減は変えません。")
                Text("勤務・休憩の変更が正しいことを確認してください。")
                Button("訂正を確定") { commit(value) }
                    .disabled(!current)
                Button("キャンセル") { proposal = nil }
                if !current {
                    Text("記録または入力が変わりました。再確認してください。")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }

        private func prepare() {
            proposal = nil
            notice = nil
            guard let intent else { return }
            do {
                proposal = try model.previewSchemaTwoRestBoundary(intent, day: day, historical: historical)
            } catch {
                notice = "時刻、隣接区間、未観測時間を確認してください。まだ保存していません。"
            }
        }

        private func commit(_ value: JournalV2ConfirmedRestBoundary) {
            guard intent == value.intent else {
                proposal = nil
                return
            }
            proposal = nil
            do {
                try model.commitSchemaTwoRestBoundary(value)
                notice = "休憩境界を訂正しました。"
                onSaved?()
            } catch JournalV2WorktimeCorrectionError.staleProposal {
                notice = "訂正案が失効しました。再確認してください。"
            } catch {
                notice = "保存結果を確認できません。自動再試行せず最新記録を確認してください。"
            }
        }

        private func worked(_ value: WorktimeGlance) -> String {
            "\(value.snapshot.bounds.lower)〜\(value.snapshot.bounds.upper)秒"
        }

        private func forecast(_ value: WorktimeGlance) -> String {
            guard case let .projected(_, departure) = value.forecast.goal else { return "未確定・対象外" }
            return label(departure)
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant))
                .formatted(.dateTime.year().month().day().hour().minute().second())
        }
    }
#endif
