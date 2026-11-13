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
