# 性能検証手順（初期リリース前）

## 目的

観測・描画・永続化・通知の負荷を区別し、勤務記録の信頼性を落とさずに改善効果を測る。未計測の状態でCPU/RAM/電池の削減率を確定しない。

## 1. 保存層ベンチマーク

実データを使用せず、10/100/500勤務日の終了済みjournal（20/200/1000 events）を一時SQLiteへ投入する。通常テストでは10日のfixture整合性のみを確認。測定は明示的に実行する。

```sh
WORKTIME_BENCHMARK=1 swift test --package-path Packages/WorktimeDomain -c release --filter CatalogBenchmarkTests
```

同一DBについて通常load（SQLite読取・JSON decode・replay）と検証済みsnapshotの再利用（SQLite読取・bytes照合）を各10回測定し、中央値・最大値・payload bytesを出力する。各回のcatalog/version同値を確認する。fixture生成と初回検証を計測区間に含めない。OSファイルキャッシュは温まっており、cold launch計測ではない。時間のハード閾値は設けない。現在の結果は未計測。

## 2. macOS実機の常駐測定

Developer IDなしの検証済み候補を隔離テストアカウントで起動する。実際の勤務記録は投入しない。機器、OS、architecture、アプリsource SHA、電源状態、画面・通知設定を記録し、比較条件を固定する。

| 状態 | 計測区間 | 確認内容 |
|---|---|---|
| 未勤務/退勤済み・画面閉 | 5分以上 | CPU、RSS、タイマー、通知 |
| 勤務中・画面閉 | 5分以上 | CPU、RSS、heartbeat |
| 勤務中・Glass表示 | 5分以上 | CPU、RSS、描画、表示遅延 |
| 休憩中 | 5分以上 | CPU、RSS、復帰操作 |
| 通知有効/無効 | 同一状態ごと | pending確認と再調整 |
| スリープ/復帰 | 別試験 | 要確認区間、時計異常、通知取消 |

Activity Monitorまたは Instruments でCPU、メモリ、Energy Impact、Time Profilerを記録する。UIと通知の操作確認を別途行う。サンプル取得の負荷は記録する。CPU/RSSの単発値を平均/ピークと混同しない。消費電力はOS指標だけでは断定しない。

## 3. 採用判断

- 正確性: 観測空白判定、時計異常検知、保存CAS、通知鮮度検証に退行がない。
- 性能: 同一条件で実測し、改善率と追加メモリを報告する。負荷のばらつきが大きければ反復を増やす。
- 安全性: 実データのコピー、通知の内容や履歴の外部送信、強制削除を行わない。
- 未確定: CPU/RSS/起動時間・電池の数値SLO。実機ベースライン後に決める。

初期リリースの合否は性能測定だけでは決定しない。通知・復旧・操作・署名/配布候補の受入確認を別に行う。
