# Proposal: SchneeWorktime MVP

## Why
フレックス勤務の出社時刻や実際の休憩によって必要実働7時間の到達時刻が変わる。基準定時、日次目標超過、正式な残業を混同しないデスクトップ常駐アプリが必要。

## What Changes
- `Lamy210/template` を開発基盤として新規macOSアプリを構築。SchneeGlassの半透明NSPanel UXを参考にする（コード/権限の無条件移植はしない）。
- 手動の出社・休憩・退勤・訂正をローカルに記録する。勤務記録IDによる日跨ぎ再開と、訂正履歴を含む原子的保存を保証する。
- 日次目標420分、標準休憩60分、任意の基準終業時刻（初期18:00）を扱う。
- 実働最短達成時刻と未取得休憩を仮定した退勤見込みを分離する。休憩予定の当日上書きを許し、実績とは混合しない。
- スリープ・アプリ終了中の未確認時間は上下限と確認待ち状態で管理し、7時間達成の確実性と到達時刻の確実性を分けて表示する。
- OSの見込み通知とアプリ確認済みの達成を区別し、通知の予約・取消・再調整、スリープ復帰・時刻異常の再評価、履歴復旧を実装する。
- アプリは正式な勤怠・賃金・法定残業の認定を行わない。

## Capabilities
### New Capabilities
- `work-session`: 明示打刻・勤務日・状態遷移・訂正
- `break-management`: 休憩の予定/実績と不明な終了時刻
- `time-projection`: 実働・残り時間・最短目標・退勤見込み
- `reference-and-surplus`: 基準定時・日次目標超過・残業との区別
- `local-notifications`: 権限、時刻予約、再調整、重複抑止
- `desktop-surface`: Glass風パネルとメニューバー操作
- `local-settings-and-recovery`: 設定・永続化・復元・エクスポート

### Modified Capabilities
なし（新規アプリ）。

## Impact
- Swift 6、SwiftUI、AppKit、UserNotifications、ServiceManagementを利用する設計。
- macOS 15+を仮の最低対象とし、Xcode実機/CIで検証する。
- サーバー、認証、クラウド、外部勤務システムとの接続は不要。
- templateはCI/配布土台であり、Xcodeアプリ本体は新規作成する。

## Out of Scope
- 会社の勤怠確定、フレックス清算期間/月間法定残業/割増賃金算定
- カレンダー/GPS/離席/スクリーンロックからの自動打刻
- 端末間同期、Apple Watch、ブラウザ版、クラウド収集
