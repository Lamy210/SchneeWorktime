#if os(macOS)
    import Foundation
    import SwiftUI
    import WorktimeApplication
    import WorktimeDomain

    /// Non-mutating desktop entry point for a validated schema-2 Journal.
    /// A saved "working" state does not imply continuously observed attendance.
    @MainActor
    struct SchemaTwoReadOnlyHistoryView: View {
        @ObservedObject var model: DesktopModel
        @State private var page: JournalV2ReadOnlyInspection?
        @State private var notice: String?

        private var displayed: JournalV2ReadOnlyInspection? {
            page ?? model.schemaTwoInspection
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Label("schema-2 · 履歴の読み取り専用確認", systemImage: "lock.shield")
                    .font(.headline)
                Text("この画面では打刻・休憩・訂正・通知予約・復元・削除はできません。保存済みの記録だけを表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reason = model.message {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                if let snapshot = displayed {
                    historyContent(snapshot)
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                Button("schema-2履歴を再検証") {
                    page = nil
                    notice = nil
                    model.open(create: false)
                }
                .disabled(model.choosingBackupDestination || model.maintenanceInProgress)
                Text("閲覧は同期・復旧・保存を行いません。書込み可能な正式UIと受入検証は未完成です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: model.schemaTwoInspection?.version) { _, _ in
                page = nil
                notice = nil
            }
        }

        @ViewBuilder
        private func historyContent(_ snapshot: JournalV2ReadOnlyInspection) -> some View {
            summary(snapshot)
            Divider()
            Text("退勤済みの勤務履歴").font(.headline)
            let history = snapshot.history
            Text("revision \(history.version.revision) · \(history.totalEndedDays)件")
                .font(.caption)
            pageControls(snapshot)
            if history.rows.isEmpty {
                Text("退勤済みの履歴はありません。").font(.caption)
            }
            ForEach(history.rows) { row in
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(time(row.startedAt)) 〜 \(time(row.endedAt))")
                        .font(.caption)
                    Text("実働：\(duration(row.worked))").font(.caption)
                    Text("休憩：\(DepartureCountdown.duration(row.rest))")
                        .font(.caption)
                    Text("訂正：\(row.corrections)件").font(.caption)
                }
            }
        }

        private func summary(_ snapshot: JournalV2ReadOnlyInspection) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text("記録済み勤務日：\(snapshot.workdays)件／終了済み：\(snapshot.endedDays)件")
                Text("訂正監査：\(snapshot.corrections)件")
                if let active = snapshot.activeDay {
                    Text("保存時の勤務状態：\(stateLabel(active.state))")
                    if let start = active.intervals.first?.start {
                        Text("勤務開始記録：\(time(start))")
                    }
                    if let observed = snapshot.lastObservedAt {
                        Text("最後の観測記録：\(time(observed))")
                    } else {
                        Text("稼働中の観測Checkpointはありません。")
                    }
                    Text("現在も勤務していることを証明する情報ではありません。")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }

        private func pageControls(_ snapshot: JournalV2ReadOnlyInspection) -> some View {
            let history = snapshot.history
            let start = history.rows.isEmpty ? 0 : history.offset + 1
            let end = history.offset + history.rows.count
            return HStack {
                if let previous = history.previousOffset {
                    Button("新しい履歴") { load(offset: previous, from: snapshot) }
                }
                Text("\(start)〜\(end) / \(history.totalEndedDays)")
                    .font(.caption)
                if let next = history.nextOffset {
                    Button("古い履歴") { load(offset: next, from: snapshot) }
                }
            }
        }

        private func load(offset: Int, from snapshot: JournalV2ReadOnlyInspection) {
            notice = nil
            do {
                page = try model.schemaTwoHistoryPage(offset: offset, previous: snapshot)
            } catch {
                page = nil
                notice = "保存版またはCheckpointが変化したため、履歴を再検証してください。"
            }
        }

        private func stateLabel(_ state: WorkdayState) -> String {
            switch state {
            case .working: "勤務中と記録"
            case .onBreak: "休憩中と記録"
            case .ended: "終了済み"
            }
        }

        private func duration(_ range: ClosedRange<Int64>) -> String {
            let lower = DepartureCountdown.duration(range.lowerBound)
            let upper = DepartureCountdown.duration(range.upperBound)
            return lower == upper ? lower : "\(lower)〜\(upper)"
        }

        private func time(_ instant: Int64) -> String {
            Date(timeIntervalSince1970: Double(instant))
                .formatted(.dateTime.year().month().day().hour().minute())
        }
    }
#endif
