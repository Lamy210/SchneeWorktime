#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication

    @MainActor
    struct WorktimeSummaryView: View {
        @ObservedObject var model: DesktopModel
        @State private var unit: WorktimeSummaryUnit = .week
        @State private var summary: WorktimeSummary?
        @State private var notice: String?

        var body: some View {
            DisclosureGroup("勤務の振り返り") {
                Text("退勤済み記録のみ。始業日の期間で集計し、正式な勤怠・給与・清算とは別です。")
                    .font(.caption)
                Picker("集計単位", selection: $unit) {
                    Text("日").tag(WorktimeSummaryUnit.day)
                    Text("週").tag(WorktimeSummaryUnit.week)
                    Text("月").tag(WorktimeSummaryUnit.month)
                }
                .pickerStyle(.segmented)
                .onChange(of: unit) { _, _ in
                    summary = nil
                    notice = nil
                }
                Button("現在の期間を読み込む") { reload() }
                if let notice {
                    Text(notice).font(.caption)
                }
                if let summary {
                    result(summary)
                }
            }
            .disabled(!model.ready || model.choosingBackupDestination)
        }

        private func result(_ value: WorktimeSummary) -> some View {
            let current = model.controller?.isCurrent(value) == true
            return VStack(alignment: .leading, spacing: 6) {
                Text(periodLabel(value.period)).font(.headline)
                Text("タイムゾーン：\(value.period.timeZoneID) · revision \(value.version.revision)")
                    .font(.caption)
                Text("読込：\(dateLabel(value.loadedAt, zone: value.period.timeZoneID, includeTime: true))")
                    .font(.caption)
                HStack {
                    Button("前の期間") { move(from: value, previous: true) }
                    Button("次の期間") { move(from: value, previous: false) }
                        .disabled(value.period.end > value.loadedAt)
                }
                .disabled(!current)
                if !current {
                    Text("履歴が更新されました。再読込してください。表示は以前の保存版です。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("終了済み：\(value.endedDays)件／要確認：\(value.uncertainDays)件")
                    .font(.caption)
                Text("実働：\(duration(value.worked))").font(.headline)
                Text("実績休憩：\(DepartureCountdown.duration(value.recordedRest))")
                Text("目標合計：\(DepartureCountdown.duration(value.target))")
                Text("日次不足合計：\(duration(value.dailyShortfall))")
                Text("日次超過合計：\(duration(value.dailySurplus))")
                Text("日次不足と超過は相殺しません。").font(.caption)
                WorktimeDailyChart(summary: value)
                Button("この集計をCSVで保存") { export(value) }
                    .disabled(!current || model.reviewProposal != nil)
            }
        }

        private func export(_ value: WorktimeSummary) {
            guard model.ready, model.sessionLock != nil, !model.choosingBackupDestination,
                  model.reviewProposal == nil, model.controller?.isCurrent(value) == true
            else { return }
            model.choosingBackupDestination = true
            defer { model.choosingBackupDestination = false }
            let initial = try? model.databaseURL().deletingLastPathComponent()
            guard let directory = WorktimeExportFormat.csv.chooseDirectory(initialDirectory: initial) else { return }
            guard model.ready, model.sessionLock != nil, model.reviewProposal == nil,
                  let controller = model.controller
            else {
                notice = "勤務記録が変わりました。CSVは保存していません。"
                return
            }
            let name = "SchneeWorktime-summary-\(UUID().uuidString).csv"
            do {
                try controller.writeSummaryCSV(value, to: directory.appendingPathComponent(name),
                                               sample: DesktopModel.sample())
                notice = "保存しました：\(name)"
            } catch {
                notice = "集計または保存先を確認してください。既存ファイルは上書きしません。"
            }
        }

        private func reload() {
            summary = nil
            notice = nil
            do {
                let sample = try DesktopModel.sample()
                let period = try WorktimeSummaryPeriod(
                    containing: sample.wall, unit: unit, timeZoneID: TimeZone.current.identifier
                )
                summary = try read(period, sample: sample)
            } catch {
                notice = "集計を読み込めません。時計と勤務記録を確認してください。"
            }
        }

        private func move(from value: WorktimeSummary, previous: Bool) {
            notice = nil
            do {
                let sample = try DesktopModel.sample()
                let period = try value.period.adjacent(previous: previous)
                guard period.start <= sample.wall else { return }
                summary = try read(period, sample: sample, previous: value)
            } catch {
                summary = nil
                notice = "期間を移動できません。現在の期間から再読込してください。"
            }
        }

        private func read(
            _ period: WorktimeSummaryPeriod, sample: ClockSample, previous: WorktimeSummary? = nil
        ) throws -> WorktimeSummary {
            guard model.ready, !model.choosingBackupDestination, let controller = model.controller else {
                throw WorktimeSummaryError.staleSummary
            }
            return try controller.summary(period: period, sample: sample, previous: previous)
        }

        private func duration(_ range: ClosedRange<Int64>) -> String {
            let lower = DepartureCountdown.duration(range.lowerBound)
            let upper = DepartureCountdown.duration(range.upperBound)
            return lower == upper ? lower : "\(lower)〜\(upper)"
        }

        private func periodLabel(_ period: WorktimeSummaryPeriod) -> String {
            let first = dateLabel(period.start, zone: period.timeZoneID)
            let last = dateLabel(period.end - 1, zone: period.timeZoneID)
            return first == last ? first : "\(first)〜\(last)"
        }

        private func dateLabel(_ instant: Int64, zone: String, includeTime: Bool = false) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: zone)
            formatter.dateStyle = .medium
            formatter.timeStyle = includeTime ? .short : .none
            return formatter.string(from: Date(timeIntervalSince1970: Double(instant)))
        }
    }
#endif
