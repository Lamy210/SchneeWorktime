#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct SchemaTwoClockBoundaryView: View {
        @ObservedObject var model: DesktopModel
        let day: Workday
        var historical: HistoricalReviewContext?
        var onSaved: (() -> Void)? = nil
        @State private var editingStart = true
        @State private var minutes = ""
        @State private var unit: WorktimeSummaryUnit = .day
        @State private var proposal: JournalV2ConfirmedClockBoundary?
        @State private var notice: String?

        private var original: Int64? {
            guard day.state == .ended else { return nil }
            if editingStart {
                guard let first = day.intervals.first, first.kind == .work, first.end != nil else { return nil }
                return first.start
            }
            guard let last = day.intervals.last, last.kind == .work else { return nil }
            return last.end
        }

        private var intent: JournalV2ClockBoundaryIntent? {
            guard let original, let offset = Int64(minutes),
                  offset != 0, (-1440 ... 1440).contains(offset)
            else { return nil }
            let (new, overflow) = original.addingReportingOverflow(offset * 60)
            guard !overflow else { return nil }
            if editingStart {
                let summary = ClockInSummarySelection(unit: unit, timeZoneID: TimeZone.current.identifier)
                return .clockIn(old: original, new: new, summary: summary)
            }
            return .clockOut(old: original, new: new)
        }

        var body: some View {
            if day.state == .ended {
                DisclosureGroup("始業・終業時刻の訂正（schema-2）") {
                    Picker("訂正対象", selection: $editingStart) {
                        Text("始業").tag(true)
                        Text("終業").tag(false)
                    }
                    if let original {
                        editor(original)
                    } else {
                        Text("先頭または末尾が勤務区間でない記録は対象外です。").font(.caption)
                    }
                    if let proposal {
                        confirmation(proposal)
                    }
                    if let notice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                    }
                }
                .disabled(!model.schemaTwoReviewEnabled)
                .onChange(of: editingStart) { _, _ in proposal = nil }
                .onChange(of: minutes) { _, _ in proposal = nil }
                .onChange(of: unit) { _, _ in proposal = nil }
                .onChange(of: day) { _, _ in proposal = nil }
            }
        }

        private func editor(_ original: Int64) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("元の時刻：\(label(original))")
                TextField("変更分（分、前倒しは負数）", text: $minutes)
                if editingStart {
                    Picker("集計確認の単位", selection: $unit) {
                        Text("日").tag(WorktimeSummaryUnit.day)
                        Text("週").tag(WorktimeSummaryUnit.week)
                        Text("月").tag(WorktimeSummaryUnit.month)
                    }
                    .pickerStyle(.segmented)
                    Text("捕捉した勤務日・参考終業時刻が変わる訂正はできません。")
                }
                Text("±1440分以内。表示と集計は現在のタイムゾーンです。")
                Button("訂正案を確認") { prepare() }
                    .disabled(intent == nil)
            }
            .font(.caption)
        }

        private func confirmation(_ value: JournalV2ConfirmedClockBoundary) -> some View {
            let current = model.schemaTwoWorkSession?.isCurrent(value) == true && intent == value.intent
            return VStack(alignment: .leading, spacing: 5) {
                Text("訂正案（未保存）").font(.headline)
                changes(value.correction)
                if value.correction.movesSummaryPeriod {
                    Text("集計期間が移動します。両方の期間を確認してください。")
                        .foregroundStyle(.orange)
                }
                ForEach(value.correction.summaryImpacts, id: \.period.start) { impact in
                    ClockInSummaryImpactView(impact: impact)
                }
                Text("変更した区間の勤務実績が正しいことを確認してください。")
                Button("訂正を確定") { commit(value) }
                    .disabled(!current)
                Button("キャンセル") { proposal = nil }
                if !current {
                    Text("記録または入力が変わりました。再確認してください。")
                }
            }
            .font(.caption)
        }

        private func changes(_ value: JournalV2WorktimeCorrectionProposal) -> some View {
            let before = value.before
            let after = value.after
            return VStack(alignment: .leading, spacing: 3) {
                if let old = before.day.intervals.first?.start, let new = after.day.intervals.first?.start {
                    Text("始業：\(label(old)) → \(label(new))")
                }
                if let old = before.day.intervals.last?.end, let new = after.day.intervals.last?.end {
                    Text("終業：\(label(old)) → \(label(new))")
                }
                Text("実働：\(worked(before)) → \(worked(after))")
                Text("日次不足：\(duration(before.forecast.remaining)) → \(duration(after.forecast.remaining))")
                Text("日次超過：\(duration(before.forecast.surplus)) → \(duration(after.forecast.surplus))")
            }
        }

        private func prepare() {
            proposal = nil
            notice = nil
            guard let intent else { return }
            do {
                proposal = try model.previewSchemaTwoClockBoundary(intent, day: day, historical: historical)
            } catch {
                notice = "時刻、隣接勤務日、未観測区間、参考時刻を確認してください。未保存です。"
            }
        }

        private func commit(_ value: JournalV2ConfirmedClockBoundary) {
            guard intent == value.intent else {
                proposal = nil
                return
            }
            proposal = nil
            do {
                try model.commitSchemaTwoClockBoundary(value)
                notice = "訂正を保存しました。"
                onSaved?()
            } catch JournalV2WorktimeCorrectionError.staleProposal {
                notice = "訂正案が失効しました。最新記録から再確認してください。"
            } catch {
                notice = "保存結果を確認できません。自動再試行せず最新記録を確認してください。"
            }
        }

        private func worked(_ value: WorktimeGlance) -> String {
            duration(value.snapshot.bounds.lower ... value.snapshot.bounds.upper)
        }

        private func duration(_ value: ClosedRange<Int64>) -> String {
            value.lowerBound == value.upperBound
                ? "\(value.lowerBound)秒"
                : "\(value.lowerBound)〜\(value.upperBound)秒"
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant))
                .formatted(.dateTime.year().month().day().hour().minute().second())
        }
    }
#endif
