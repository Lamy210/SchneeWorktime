# SchneeWorktime 設計ノート

正式な変更仕様: [OpenSpec change](../../openspec/changes/initial-worktime-mvp/proposal.md)

- [仕様決定](SPEC_DECISIONS.md)
- [受入テスト](ACCEPTANCE_MATRIX.md)
- [未確定事項](OPEN_QUESTIONS.md)
- [PR #4レビュー記録](REVIEW_FINDINGS.md)
- [勤務日の状態・データ契約](WORKDAY_CONTRACT.md)
- [検証戦略](TEST_STRATEGY.md)
- [退勤見込みと試算の契約](FORECAST_SEMANTICS.md)
- [通知のカテゴリと基準時刻](NOTIFICATION_POLICY.md)
- [新機能の候補と優先順位](FEATURE_DISCOVERY.md)
- [日々の利用シナリオとUI](UX_JOURNEYS.md)
- [M0/M1/M2のリリース範囲](RELEASE_SCOPE.md)
- [技術設計](../../openspec/changes/initial-worktime-mvp/design.md)
- [開発タスク](../../openspec/changes/initial-worktime-mvp/tasks.md)

`Lamy210/template`から生成したリポジトリの初回仕様ドラフト。現時点では**設計と初期Domain実装**。SwiftUI/macOSアプリ本体は未実装。v0.7ではレビュー指摘の仕様矛盾を整理し、純粋なSwiftPM Domainの初期実装を追加。OpenSpec CLI、ビルド・OS通知の実行検証は未実施。レビュー後に採用し、`openspec validate initial-worktime-mvp --strict` を実行する。

仕様の真偽の境界:
- 事実: 7時間/休憩60分のユーザー指定、既存templateのCI/配布基盤、Apple通知API。
- 仕様上の仮定: 18:00参考時刻、ローカル手動記録、macOS 15+。
- 未確認: 会社の正式な清算期間・残業規則、macOS実機でのUI/通知/性能。

Domain単体テスト: `swift test --package-path Packages/WorktimeDomain`。Linux Swift 6.2.1で6件成功。OpenSpec CLIおよびMac実機は未検証。
