# SchneeWorktime 設計ノート

正式な変更仕様: [OpenSpec change](../../openspec/changes/initial-worktime-mvp/proposal.md)

- [仕様決定](SPEC_DECISIONS.md)
- [受入テスト](ACCEPTANCE_MATRIX.md)
- [未確定事項](OPEN_QUESTIONS.md)
- [PR #4レビュー記録](REVIEW_FINDINGS.md)
- [勤務日の状態・データ契約](WORKDAY_CONTRACT.md)
- [検証戦略](TEST_STRATEGY.md)
- [障害時の保全・復旧手順](RECOVERY_RUNBOOK.md)
- [限定ロールバック](ROLLBACK.md)
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
- 起動時の未終了勤務は最後の開いた勤務開始から現在までを保守的に要確認とする。最新勤務日の複数の要確認区間から、勤務継続・休憩・非勤務のいずれかを選び、訂正前後の実働と見込みを確認して明示保存できる。区間全体または秒単位の部分訂正に対応し、過去日の選択・訂正は未実装。監視の暫定15秒閾値と時計差2秒はリリース確定値ではない。

この時点でmacOS GUIのビルド・操作は未検証。開発版であり正式な勤怠記録用途や配布MVPの完了を主張しない。Linux向け実行入口は未対応OSの案内のみでGUIを提供しない。

### 次の勤務日の設定と退勤時刻の試算
メニューバーから次回の実働目標・標準休憩を設定できる。初期値420分/60分。試作の入力範囲は目標5〜1440分、休憩0〜1440分、5分刻み。UserDefaultsに保存し、新規勤務開始時だけ検証済みprofileをSQLiteに保存する。既存勤務日のprofileは変更しない。
退勤候補（分単位）・仮の復帰時刻・今帰るを選び、最新の観測時刻に対する仮定の実働・休憩・目標不足/超過の範囲を表示する。過去・実現不能・復帰不明を区別し、実績・退勤希望の保存・通知設定を変更しない。macOS GUIと新規テストは未検証。希望退勤の明示保存、参考終業時刻の固定保存、当日の残り休憩予定変更に対応する。実機は未検証。

### ローカル配布候補の作成（署名・公証・公開なし）
macOS 15以降で以下を実行する。出力先は新規の専用ディレクトリとする。既存 .app は上書きしない。

```sh
swift test --package-path Packages/WorktimeDomain
swift build --package-path Packages/WorktimeDomain -c release --product SchneeWorktime
bin_dir="$(swift build --package-path Packages/WorktimeDomain -c release --show-bin-path)"
stage="$(mktemp -d)"
python3 scripts/release/build_worktime_bundle.py --binary "$bin_dir/SchneeWorktime" \
  --output "$stage/SchneeWorktime.app" --version 0.1.0
plutil -lint "$stage/SchneeWorktime.app/Contents/Info.plist"
open "$stage/SchneeWorktime.app"
```

暫定bundle ID: `uk.lamysnow.schneeworktime`、暫定検証用バージョン: 0.1.0。安定公開前に固定すること。CIは実バイナリでバンドルとtarを検証するが配布しない。Python単体テストは疑似Mach-O fixtureで、実機起動の証明ではない。署名済みDMG・Gatekeeper・公証・公開・Homebrewの接続は未完了。ローカル検証では隔離アカウントを利用し、既存勤務データのバックアップを取る。

### 排他起動と保存先の保護
DBを開く前に `session.lock` を取得し、同一保存先を使う協調アプリの同時書込みセッションを拒否する。再読込中もロックを保持し、プロセス終了でOSが解放する。ロックファイルは削除しない。保存ディレクトリは現在の利用者所有でグループ/その他のアクセス権なし、最終パス要素はシンボリックリンク不可。ロックファイルの既存権限・所有者・リンクを検査し、危険時は自動修復せず停止する。既存ディレクトリの権限が広い場合はバックアップを取ってから信頼できる保存先か確認すること。これは協調ロックであり、他のプログラムの直接SQLiteアクセスや同一ユーザーの悪意ある操作を防ぐ仕組みではない。DBファイル/sidecarとACL・パス祖先の安全性、macOSの複数プロセス試験は未検証。

### 退勤準備通知の試作接続
署名・公証前の.appでも通知動作を実機で確認する必要がある。メニューの「勤務の通知」から明示的に許可を要求する。初期状態は無効。退勤準備30/15/5分前（15分前が既定）、最短達成15分前、参考終業を独立設定できる。勤務記録保存後と起動中15秒周期で予約を再調整し、通知失敗は勤務記録をロールバックしない。保存読取失敗と時計異常では所有通知の取消を試み、無効化・不確定な見込みでは不適格な通知を抑制する。通知の配信、既配信の取消、終了後の通知配送は保証しない。実機検証未完了。超過見込みの通知は未実装。

### 勤務履歴バックアップ（開発版）
メニューバーの「勤務履歴のバックアップ」から、所有者専用のローカルフォルダを明示選択する。既存DBは変更せず、確定済み履歴・訂正監査をUUID付きの新規JSONに保存する。同期フォルダを避けること。平文のため共有・持ち出しには注意が必要。未保存訂正・グローバル設定・Heartbeatは含まない。正常DBの同一世代の過去の終了済み履歴に限り、明示確認と保全付き復元に対応する。macOS実機での操作は未検証。

### Developer ID不要の初期配布
初期配布はDeveloper ID署名・公証なし（ad-hoc署名は付与）とする。[配布手順](UNSIGNED_RELEASE.md) を優先する。手動候補生成、チェックサム検証と実機QAを経て公開する。署名済みDMG・公証・Homebrewは初期リリースの必須条件ではない。
