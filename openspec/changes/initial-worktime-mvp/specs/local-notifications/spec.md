# Spec Delta

## Purpose
実働目標・基準終業時刻などの未来の通知をローカルに計画し、記録訂正や休憩変更に追随して重複や古い予約を可能な限り減らす。

## ADDED Requirements

### Requirement: Independent notification categories
The system SHALL make reference-end, earliest-goal pre-alert, forecast at goal, and conditional daily surplus reminders independently configurable, and SHALL distinguish predictions from confirmed records.

#### Scenario: Before goal
- **WHEN** 休憩実績60分、目標時刻19:30、15分前通知が有効
- **THEN** 19:15に目標接近の通知を予約する

#### Scenario: No rest projected
- **WHEN** 11:30出社・休憩未取得で最短目標18:30、休憩込み見込み19:30
- **THEN** 目標15分前通知は18:15を使い、仮定の退勤19:30は目標到達通知に使わない

#### Scenario: Reference reached
- **WHEN** 基準終業時刻18:00、勤務中で通知許可あり
- **THEN** 基準時刻到達という別カテゴリの通知を予約する

### Requirement: Reconcile pending future requests
The system SHALL derive a deterministic finite desired notification set from the latest committed workday revision, cancel obsolete pending requests and add missing future requests. It SHALL not schedule elapsed notifications retroactively.

#### Scenario: Break extends
- **WHEN** 休憩終了が13:00から13:30へ訂正される
- **THEN** 旧目標関連の将来通知を削除し、新しい予測に基づく通知へ置き換える

#### Scenario: Restart too late
- **WHEN** 15分前通知予定時刻を過ぎてアプリが再起動する
- **THEN** 過去の15分前通知を遡って送信しない

#### Scenario: Idempotent reconcile
- **WHEN** 同じrevisionで通知再調整を2回実行する
- **THEN** 最新のpending予約の論理ID集合が重複なく一致する

### Requirement: Permission and delivery limitations
The system SHALL remain fully functional without notification authorization and SHALL communicate that OS delivery timing, exactly-once appearance and cancellation of already delivered items are not guaranteed.

#### Scenario: Denied authorization
- **WHEN** 通知が拒否された環境で勤務を記録する
- **THEN** 勤務計算と保存を継続し、強制許可ダイアログを繰り返さない

#### Scenario: Cancel race
- **WHEN** 通知の発火直前に休憩修正を保存する
- **THEN** 最新のpending予約に収束しつつ、OSが既に配信した通知の完全取消は保証しない

### Requirement: Only committed state schedules
The system SHALL persist an accepted change before notification reconciliation. A failed persistence operation SHALL leave canonical state and intended notification set unchanged.

#### Scenario: Storage fails
- **WHEN** 勤務訂正の書き込みが失敗する
- **THEN** 修正を確定表示せず、以前の記録と通知計画を維持する

#### Scenario: Notification fails
- **WHEN** 勤務訂正保存は成功し通知追加のみ失敗する
- **THEN** 記録は保持し、再試行できる非致命的警告を示す

### Requirement: Scheduled reminders are forecasts only
The system SHALL label pre-scheduled goal and surplus notifications as conditional forecasts, not proof of attendance. It SHALL issue confirmed-achievement messaging only after validated committed intervals reach the target without unresolved uncertainty.

#### Scenario: Future goal reminder when suspended
- **WHEN** OSが予約済みの18:30目標通知をアプリ休止中に配信する
- **THEN** 「目標到達の見込みです。記録をご確認ください」と表現し、7時間達成を断定しない

#### Scenario: Confirmed goal in running process
- **WHEN** 計測済み勤務が420分に達し未確認区間がない
- **THEN** アプリは実績達成として表示し、見込み通知と区別できる

#### Scenario: Unverified target
- **WHEN** 累積時間に未確認のスリープ区間が含まれる
- **THEN** 確定達成通知を出さず記録確認を案内する

### Requirement: Trigger-sensitive request reconciliation
The system SHALL compare each owned pending notification's identifier, trigger Instant and payload revision when reconciling, and SHALL replace outdated requests rather than trusting matching identifiers alone.

#### Scenario: Same ID different time
- **WHEN** 目標時刻が19:30から20:00へ変わる
- **THEN** 旧19:30の予約を削除対象とし新20:00のリクエストへ収束させる

#### Scenario: Crash after commit before schedule
- **WHEN** 履歴の新revisionを保存後、通知変更前にアプリが終了する
- **THEN** 次回起動時に保存済みrevisionから未来予約を再構築する

### Requirement: Bounded and privacy-safe reminders
The system SHALL configure a finite set of threshold reminders and SHALL hide employer name and detailed attendance history from default lock-screen notification text.

#### Scenario: Surplus thresholds
- **WHEN** 超過見込みの通知閾値を15分、30分、60分とする
- **THEN** 各閾値につき最大1件の予定通知を管理し毎分通知しない

#### Scenario: Locked screen
- **WHEN** 画面ロック中に勤務通知が配信される
- **THEN** 会社名・出社時刻・休憩履歴を本文に含めない

### Requirement: Do not schedule precise goal reminders when time is ambiguous
The system SHALL cancel unexpired precise goal and surplus forecasts when unresolved uncertainty makes a single target Instant impossible, while leaving independently valid reference-time reminders unaffected.

#### Scenario: Sleep creates uncertain goal range
- **WHEN** 目標達成時刻が未確認スリープによって18:30〜19:30の範囲になる
- **THEN** 単一時刻の未達・超過予報通知を予約せず、勤務記録の確認をUIへ提示する

#### Scenario: User resolves uncertain time
- **WHEN** 利用者が未確認区間を修正して目標時刻が再び一意になる
- **THEN** 最新のcommitted revisionから将来の見込み通知を再生成する

### Requirement: Avoid double achievement alerts
The system SHALL default to one user-visible OS forecast reminder per goal threshold and SHALL show subsequent verified achievement as an in-app state, not a second automatic OS notice, unless explicitly enabled by user preferences.

#### Scenario: Forecast then confirmed while app runs
- **WHEN** 18:30のOS見込み通知を配信した後アプリが検証済み実働7時間を認識する
- **THEN** UIは達成済みに更新するが、既定では同一イベントの2通目のOS通知を送らない

### Requirement: Delivery depends on OS permissions and active process
The system SHALL preserve accurate in-app timing regardless of notification permission and SHALL treat pending OS notifications as best-effort reminders subject to sleep, user Focus settings, app termination and cancellation races.

#### Scenario: Notification disabled during work
- **WHEN** macOSの通知許可を後から取り消す
- **THEN** 記録と予測は継続し、設定に通知が無効なことを示す

#### Scenario: Break started while goal reminder pending
- **WHEN** 勤務中の目標予測通知が予約済みで利用者が休憩を開始する
- **THEN** 正確な休憩終了時刻が不明なため未来の目標予報通知を削除対象とし、基準終業通知は独立して維持する
