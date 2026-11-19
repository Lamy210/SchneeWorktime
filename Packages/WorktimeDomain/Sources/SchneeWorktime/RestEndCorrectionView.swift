#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    @MainActor
    struct RestEndCorrectionView: View {
        @ObservedObject var model: DesktopModel
        let day: Workday
        let boundary: RestBoundary
        let historical: HistoricalReviewContext?
        @State private var selectedEnd: Int64
        @State private var offsetMinutes = "30"
        @State private var proposal: WorktimeRestEndProposal?
        @State private var notice: String?

        init(
            model: DesktopModel, day: Workday, boundary: RestBoundary = .end,
            historical: HistoricalReviewContext? = nil
        ) {
            self.model = model
            self.day = day
            self.boundary = boundary
            self.historical = historical
            _selectedEnd = State(initialValue: Self.boundaries(day, boundary: boundary).first ?? 0)
        }

        private var boundaryLabel: String {
            boundary == .start ? "休憩開始" : "休憩終了"
        }

        private static func boundaries(_ day: Workday, boundary: RestBoundary) -> [Int64] {
            let leftKind: IntervalKind = boundary == .start ? .work : .rest
            let rightKind: IntervalKind = boundary == .start ? .rest : .work
            return zip(day.intervals, day.intervals.dropFirst()).compactMap { left, right in
                guard left.kind == leftKind, right.kind == rightKind, left.end == right.start else { return nil }
                return left.end
            }
        }

        var body: some View {
            let ends = Self.boundaries(day, boundary: boundary)
            if !ends.isEmpty {
                DisclosureGroup("記録済み\(boundaryLabel)時刻の訂正") {
                    editor(ends)
                    if let proposal {
                        confirmation(proposal)
                    }
                    if let notice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                    }
                }
                .disabled(!model.ready || model.choosingBackupDestination || model.reviewProposal != nil)
            }
        }

        private func editor(_ ends: [Int64]) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Picker("元の\(boundaryLabel)", selection: $selectedEnd) {
                    ForEach(ends, id: \.self) { end in
                        Text(label(end)).tag(end)
                    }
                }
                TextField("変更分（分、前倒しは負数）", text: $offsetMinutes)
                Button("訂正案を確認") { prepare() }
            }
            .onChange(of: selectedEnd) { _, _ in proposal = nil }
            .onChange(of: offsetMinutes) { _, _ in proposal = nil }
        }

        private func confirmation(_ value: WorktimeRestEndProposal) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(boundaryLabel)：\(label(value.oldEnd)) → \(label(value.newEnd))")
                Text("実働：\(bounds(value.before)) → \(bounds(value.after))")
                Text("実績休憩：\(value.before.snapshot.recordedRest)秒 → \(value.after.snapshot.recordedRest)秒")
                Text("退勤見込み：\(forecast(value.before)) → \(forecast(value.after))")
                Text("変更する区間の勤務・休憩実績が正しいことを確認してください。")
                Button("訂正を確定") { confirm(value) }
                    .disabled(model.controller?.isCurrent(value) != true)
                Button("キャンセル") { proposal = nil }
                if model.controller?.isCurrent(value) != true {
                    Text("保存版が変わりました。訂正案を再作成してください。")
                }
            }
            .font(.caption)
        }

        private func prepare() {
            proposal = nil
            notice = nil
            guard let minutes = Int64(offsetMinutes), minutes != 0, (-1440 ... 1440).contains(minutes) else {
                notice = "±1440分以内の0以外の整数を指定してください。"
                return
            }
            let (newEnd, overflow) = selectedEnd.addingReportingOverflow(minutes * 60)
            guard !overflow else { return }
            do {
                proposal = try model.previewRestBoundaryCorrection(
                    day: day, old: selectedEnd, new: newEnd, boundary: boundary, historical: historical
                )
            } catch {
                notice = "時刻・区間・要確認記録を確認してください。訂正案は保存されていません。"
            }
        }

        private func confirm(_ value: WorktimeRestEndProposal) {
            proposal = nil
            do {
                try model.confirmRestBoundaryCorrection(value)
                notice = "\(boundaryLabel)時刻を訂正しました。"
            } catch is CommittedCheckpointError {
                notice = "訂正は保存済みです。既存データを再読込してください。"
            } catch {
                notice = "確定結果を確認してください。再操作せず最新記録を読み込んでください。"
            }
        }

        private func bounds(_ value: WorktimeGlance) -> String {
            "\(value.snapshot.bounds.lower)〜\(value.snapshot.bounds.upper)秒"
        }

        private func forecast(_ value: WorktimeGlance) -> String {
            guard case let .projected(_, departure) = value.forecast.goal else { return "未確定・対象外" }
            return label(departure)
        }

        private func label(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant)).formatted(.dateTime.month().day().hour().minute().second())
        }
    }
#endif
