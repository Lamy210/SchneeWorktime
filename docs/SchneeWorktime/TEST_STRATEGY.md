# Verification Strategy — SchneeWorktime v0.7

## 1. Test layers
| 層 | 実行環境 | 主要検証 |
|---|---|---|
| Domain unit | SwiftPM + FakeClock | 実働・休憩・目標到達上下限・秒精度・DST・日跨ぎ |
| Application integration | FakeStore/FakeNotification/FakeSystemEvents | 状態遷移、revision競合、原子的保存、通知reconciliation |
| macOS adapter | Apple実機/CI | UserNotifications権限・予約・非同期取消、NSWorkspace睡眠/起床、NSPanel |
| Manual UX | 実機 + VoiceOver | 記録訂正、予測ラベル、画面切断、キーボード、ロック画面 |

## 2. Baseline cases
- AC-01〜32: 既存実働算術・予定休憩・定時の誤認防止。
- AC-41〜53: 休憩中退勤、スリープ未確認、見込み通知。
- AC-57〜61: アプリ終了・再開・日跨ぎ・未来実績の拒否。
- AC-62〜66: 勤務の上下限・到達時刻の範囲。最も重要な計算境界。
- AC-67〜69: 将来休憩予定上書きが実績に混ざらない。
- AC-70〜75: 不確定通知抑止・再計算・原子的保存・競合。
- AC-76〜84: 設定・省電力・通知・プライバシー・表示。
- AC-85〜89: 未確認時間の3分類と予定休憩の取得済み分による消費、訂正UIの結果プレビュー。
- AC-90〜104: 過去始業入力、非破壊退勤試算、未来休憩を含めた予測、メニューバー操作、通知許可とリード時間。
- AC-105〜121: 未来休憩の実現可能性、試算失効、既定退勤通知と最短達成通知の分離、過去休憩訂正、休憩実績の確認表示。
- それ以外の既存P1はリリース前QAで確認する。

## 3. Properties to verify
1. `0 <= knownWork <= possibleWork`; `0 <= remainingMin <= remainingMax`.
2. `remainingMin=remainingMax=0` whenever `knownWork>=target` and all intervals are temporally valid.
3. Closed workdays do not accrue hours after clock-out, including process restart or change in wall clock.
4. No future actual timestamp and no double active workday.
5. A correction never results in mismatched workday and audit revisions.
6. Forecast break override does not mutate recorded breaks.
7. Reconcile uses the committed latest revision and avoids stale/duplicate owned pending requests, as far as the OS can guarantee.
8. No official overtime/pay language appears as a calculation result.

## 4. Fault injection
- Crash during app-wide transaction, disk full, invalid schema, catalog/active ID consistency, backup restore, erase epoch and stale revision commit.
- Sleep/wake with open work and open break, app forced quit and resume, system clock rollback, timezone/DST transition.
- Notification authorization denied/revoked, request already fired during cancel, repeated schedule calls.
- Display disconnected, app panel hidden, multiple UI commands racing.

## 5. Acceptance gates (proposed, not tested)
- Every P0 numerical/state machine case passes deterministically. Each AC is linked to test ID.
- OpenSpec strict validation succeeds on exact PR HEAD (currently not executed).
- macOS real hardware QA demonstrates correct behavior; template-only CI green is insufficient.
- Runtime CPU/RAM/battery and app start-up are measured before quantitative performance thresholds are accepted.
- Template Release Isolation failure is corrected without relaxing security checks (hermetic git/gh fixture; a8c5b5d1 Release Isolation TDD/Quality passed).

### 新たに必須となる境界テスト
- `candidate<now`: future what-ifを拒否。`candidate==now`: 実績だけ算定。`candidate>now`: 未来休憩が差分に収まるかを確認。
- `futureBreak>availableWindow`: 実現不能。`==`: 将来の実働増分0。`<`: 条件付き算定。
- Workday revisionが変わると既存previewは無効。予定保存前に再試算する。
- デフォルト通知：最短18:30/退勤見込み19:30で19:15のみ予約。最短の18:15はユーザー設定後だけ。
- 予定休憩入力前の休憩実績の訂正ではoverrideの消費量を変えない。入力後の休憩時間増加・減少に追随する。
- 7時間実働・休憩記録30分で警告しても日次目標達成は取り消さず、法的違反の断定もしない。

## v0.7 実装済み単体テストの対応（部分カバレッジ）
| Test | 対応する計算・境界 |
|---|---|
| attainment and crossing | AC-63/122 の上下限と到達範囲 |
| possible not confirmed | AC-62/44（下限未達） |
| exact before later uncertainty | AC-83 |
| reject overlap and future | AC-18/61 の一部（正規化済み区間） |
| impossible rest and leave now | AC-105〜108（計算のみ） |
| active break consumes budget once | AC-109/126〜129（計算のみ） |
初期6件はLinux Swift 6.2.1で成功。後述のTimeline実装により残休憩消費の計算部分も追加検証。UI、監査、実際の通知、保存競合、タイムゾーンは未実装・未検証。

## Timeline実装の追加検証
| Test | 対応する計算境界 |
|---|---|
| overlapping observations count once and only within work | AC-141 |
| historical rest does not consume anchored plan | AC-120/121/130の区間消費 |
| nonworking gap does not consume expected rest | AC-85の区間集計 |
| open work at clock in has zero duration | AC-142 |
| invalid timelines fail rather than being guessed | 重複・複数open interval拒否 |
11件のSwift TestingテストをLinux Swift 6.2.1で実行成功。既存の6テストと合わせた件数であり全ACの合格ではない。Testsワークフローに実際のDomain packageを必須ジョブとして追加。a8c5b5d1のmacOS CI（Apple Swift 6.3.3）で11件成功し、Tests/Required Gateも成功。最新コミットの結果はChecksを確認する。

## v0.8 WorkdayCatalog 単体テスト
| テスト | 計算/コマンド部分の対象 |
|---|---|
| work break and clock out freeze recorded time | AC-48と打刻遷移の固定 |
| clock out during break requires confirmation | AC-41/42 |
| stale and duplicate actions leave state unchanged | AC-16/17/146（値型のみ） |
| same second and future transitions are rejected without mutation | AC-61/143 |
| cross midnight resume keeps identity and excludes gap | AC-15/18/59（絶対秒の境界、timezone未実装） |
| cannot resume old day or reuse its identity | AC-60/144とUUIDの一意性 |
| profile targets are fixed and clock rollback is refused | AC-90の遡り時刻/入力済みprofile/開始前への逆転 |
Linux Swift 6.2.1で追加7件・既存11件の計18件成功。AC-145の独立回帰、実際の競合、databaseの原子性、監査付き訂正、local date/timezone、時計検出、通知/UIはいずれも未検証。
