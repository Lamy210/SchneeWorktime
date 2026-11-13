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

### Requirement: Explicit clock-out from break
The system SHALL require explicit confirmation for clock-out during an open break and SHALL close that break at the selected end Instant without inventing an additional work interval.

#### Scenario: Confirm break-end clock-out
- **WHEN** 17:00から休憩中に17:15の退勤を選択し確認する
- **THEN** 休憩を17:15で閉じ、勤務区間を追加せずendedとなる

#### Scenario: Cancel break-end clock-out
- **WHEN** 休憩中の退勤確認をキャンセルする
- **THEN** 休憩状態と勤務実績は変更されない

### Requirement: Unverified elapsed spans
The system SHALL flag active work intervals intersecting a detected sleep, clock anomaly or unexpectedly long interruption as unverified until the user explicitly confirms or corrects them. It SHALL NOT silently generate a break or clock-out.

#### Scenario: Wake during work
- **WHEN** workingのまま16:30〜17:30にMacがスリープして復帰する
- **THEN** 区間を要確認として保持し、自動休憩・自動退勤を行わない

#### Scenario: Confirm actual work
- **WHEN** 利用者が要確認区間を勤務継続として明示確認する
- **THEN** 該当区間を確認済みとし、目標達成と通知を再評価する

#### Scenario: Correct sleep as break
- **WHEN** 要確認の16:30〜17:30を休憩へ訂正する
- **THEN** 実働から60分除外し、見込みと未来通知を再計算する

### Requirement: Workday identity across midnight
The system SHALL bind continuation and resumption to a stable workday UUID rather than local calendar-day equality. It SHALL allow explicitly resuming the same ended workday after midnight if no later workday exists and the resulting intervals do not overlap another workday.

#### Scenario: Resume after midnight
- **WHEN** 21:00に開始して翌日00:30に退勤した勤務記録を、翌日01:00に明示的に再開する
- **THEN** 開始日の勤務記録IDを再利用し、00:30〜01:00を実働へ加算しない

#### Scenario: Later workday already exists
- **WHEN** 後続の勤務日が記録済みである古い勤務日を再開しようとする
- **THEN** 新しい実働区間の追加を拒否し、既存履歴の訂正導線を提示する

### Requirement: Recover uncertain app downtime
The system SHALL NOT equate application termination with clock-out. It SHALL flag an active session's unobserved period after unexpected app termination, system shutdown or restart as an uncertain span for explicit confirmation or correction.

#### Scenario: Quit without clock-out
- **WHEN** 16:00にworking状態でアプリを終了し17:00に再起動する
- **THEN** 勤務日の状態を維持し、未観測区間を要確認として提示し、退勤を捏造しない

#### Scenario: Restart while break was active
- **WHEN** onBreak状態でアプリが終了して30分後に再起動する
- **THEN** 開いた休憩が継続中として復元され、ユーザーが休憩終了時刻を訂正できる

#### Scenario: Screen lock but app remains active
- **WHEN** Macの画面のみをロックしアプリが継続稼働する
- **THEN** ロックだけを理由に休憩や退勤を自動生成しない

### Requirement: Prevent actual events in the future
The system SHALL accept actual clock-in, break and clock-out instants only at or before a trusted current Instant; future times are planning data, not attendance events.

#### Scenario: Future correction entered as actual
- **WHEN** 現在15:00なのに実績の退勤を18:00へ訂正しようとする
- **THEN** 実績としての保存を拒否し、将来の退勤予定として別操作を案内する

### Requirement: Three-way uncertain-time resolution
The system SHALL allow explicitly resolving an uncertain interval as worked, an actual unpaid break, or a non-working gap. It SHALL NOT count a non-working gap toward recorded rest or worked time, and SHALL preserve the chosen classification in the correction audit.

#### Scenario: Resolve as non-working gap
- **WHEN** 16:30〜17:30の未確認区間を「非勤務ギャップ」として訂正する
- **THEN** その60分を勤務から除外し、休憩実績にも加算しない

#### Scenario: Reclassify non-working gap as actual break
- **WHEN** 訂正済みの非勤務ギャップをさらに休憩へ訂正する
- **THEN** 勤務実績は増やさず、休憩実績に60分加え、訂正の履歴を保存する
