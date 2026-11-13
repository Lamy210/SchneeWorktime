# SchneeWorktime 設計ノート

正式な変更仕様: [OpenSpec change](../../openspec/changes/initial-worktime-mvp/proposal.md)

- [仕様決定](SPEC_DECISIONS.md)
- [受入テスト](ACCEPTANCE_MATRIX.md)
- [未確定事項](OPEN_QUESTIONS.md)
- [PR #4レビュー記録](REVIEW_FINDINGS.md)
- [技術設計](../../openspec/changes/initial-worktime-mvp/design.md)
- [開発タスク](../../openspec/changes/initial-worktime-mvp/tasks.md)

`Lamy210/template`から生成したリポジトリの初回仕様ドラフト。現時点では**設計のみ**でSwiftアプリは未実装。v0.3で休憩中退勤、未確認勤務区間、予測通知と確定通知を強化。OpenSpec CLI、ビルド・OS通知の実行検証は未実施。レビュー後に採用し、`openspec validate initial-worktime-mvp --strict` を実行する。

仕様の真偽の境界:
- 事実: 7時間/休憩60分のユーザー指定、既存templateのCI/配布基盤、Apple通知API。
- 仕様上の仮定: 18:00参考時刻、ローカル手動記録、macOS 15+。
- 未確認: 会社の正式な清算期間・残業規則、macOS実機でのUI/通知/性能。
