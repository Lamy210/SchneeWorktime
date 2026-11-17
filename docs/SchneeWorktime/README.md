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

Domain単体テスト: `swift test --package-path Packages/WorktimeDomain`。Linux Swift 6.2.1で20件成功（実働・退勤試算・区間正規化・残り休憩・普通打刻の状態遷移）。OpenSpec CLIおよびMac実機は未検証。

### 現時点の保存基盤
PR #7のmacOS CIでDomain 32件成功。WorktimeStoreのSQLite snapshotストアを追加し、隔離Linux SwiftPMで6件成功。まだアプリ本体とWorkdayCatalogのシリアライズは未接続。記録が実際に復元できるアプリが完成したわけではない。OpenSpec CLI strictおよびmacOS実機は未検証。

### SQLiteカタログ接続の開発中変更
WorktimeStoreのCatalogRepositoryとschema v1 journalを追加。勤務日カタログを保存・再生できる実装を用意したが、新規テストのCI結果は未確認。復元性能、上限、過去schema、バックアップの消去境界、UIとの連携は未完。

## メニューバー試作版（リリース前）
この変更で、macOS 15以降を対象としたSwiftPM実行ターゲット `SchneeWorktime` を追加する。

- 開発環境からの起動: `swift run --package-path Packages/WorktimeDomain SchneeWorktime`
- テスト: `swift test --package-path Packages/WorktimeDomain`
- アプリ製品のビルド: `swift build --package-path Packages/WorktimeDomain --product SchneeWorktime`
- 保存先: ~/Library/Application Support/SchneeWorktime/worktime.sqlite。初回作成は明示操作。以前のDBが消失している場合は作成せず復旧を優先する。
- メニューバーの時計アイコンで出社・休憩・退勤・再開、実働範囲・残り・休憩込み退勤見込みを確認できる設計。時刻異常・永続化エラー時は書込みを停止する。
- 起動時の未終了勤務は最後の開いた勤務開始から現在までを保守的に要確認とする。訂正画面はまだない。監視の暫定15秒閾値と時計差2秒はリリース確定値ではない。

この時点でmacOS GUIのビルド・操作は未検証。開発版であり正式な勤怠記録用途や配布MVPの完了を主張しない。Linux向け実行入口は未対応OSの案内のみでGUIを提供しない。
