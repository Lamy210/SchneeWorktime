# Spec Delta

## Purpose
勤務開始から終了までの連続した記録と、後からの訂正を、明示操作と矛盾しない状態遷移として管理する。日跨ぎと再開に耐える一意の勤務日を提供する。

## ADDED Requirements

### Requirement: Explicit transition control
The system SHALL require user intent for clock-in, break start/end, clock-out and resume. It SHALL NOT infer working from computer unlock or screen activity.

#### Scenario: Clock in
- **WHEN** 未開始の勤務日に11:30で出社操作する
- **THEN** workingになり、11:30開始の開いた勤務区間が1つ記録される

#### Scenario: Duplicate action
- **WHEN** 勤務中に出社操作が重複する
- **THEN** 別の勤務日/区間を増やさず、重複操作として扱う

#### Scenario: Clock out
- **WHEN** workingで17:00に退勤する
- **THEN** 開いている区間を17:00で閉じてendedとなる

### Requirement: One logical active workday
The system SHALL allow at most one active logical workday and SHALL retain its identifier and start-date association across midnight.

#### Scenario: Cross-midnight
- **WHEN** 21:00開始の勤務を翌日01:00まで継続する
- **THEN** 日付を跨いでも開始日の同じworkday IDを使用し、自動で勤務を分割しない

#### Scenario: Second active day
- **WHEN** 未終了の勤務が存在する状態で新しい出社を操作する
- **THEN** 重複する勤務日を作らず、既存勤務の確認を求める

### Requirement: Resume after clock-out
The system SHALL resume an ended workday only by explicit action and SHALL exclude gaps between end and resume from worked duration.

#### Scenario: Resume
- **WHEN** 17:00退勤した日の18:00に明示的に再開し18:30に退勤する
- **THEN** 元の勤務日に30分の新しい区間を追加し、17:00〜18:00は勤務に含めない

### Requirement: Validate historical corrections
The system SHALL validate all stored intervals as a whole and reject impossible, overlapping, stale-revision or zero-length corrections without changing canonical data.

#### Scenario: Overlap
- **WHEN** 訂正によって勤務区間が休憩と重なる
- **THEN** 保存を拒否し、以前の記録と通知計画を維持する

#### Scenario: Stale edit
- **WHEN** 古いrevisionから履歴を書き戻そうとする
- **THEN** 競合として拒否し、後勝ち上書きをしない

### Requirement: Uncertain continuity
The system SHALL flag potentially unverified time after sleep, system clock jump or unexpectedly long open sessions; it SHALL NOT auto-create a break or clock-out.

#### Scenario: Wake
- **WHEN** 勤務中に90分スリープして復帰する
- **THEN** 勤務の推定を行わず記録確認を促し、状態を勝手に変更しない

#### Scenario: Long open shift
- **WHEN** 16時間以上の未終了勤務を復元する
- **THEN** 要確認を提示し、自動退勤を行わない
