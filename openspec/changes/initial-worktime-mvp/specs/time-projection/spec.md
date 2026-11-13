# Spec Delta

## Purpose
記録された区間から実働と残り時間を秒精度で算出し、連続勤務ならいつ到達するかと、予測休憩を取る場合の退勤見込みを別々に示す。

## ADDED Requirements

### Requirement: Exact net-work accounting
The system SHALL sum completed work intervals and one active work interval at current Instant, excluding break and ended gaps. It SHALL compute remaining=max(0,25200-worked) and surplus=max(0,worked-25200) for the default profile.

#### Scenario: Known break
- **WHEN** 11:30開始、12:00〜13:00休憩、現在18:10である
- **THEN** 実働340分、残り80分、実働目標超過0分となる

#### Scenario: At threshold
- **WHEN** 記録上の累積実働が25200秒に到達する
- **THEN** 残り0秒、日次目標達成へ遷移する

### Requirement: Two distinct target timestamps
The system SHALL distinguish earliestGoalAt=now+remainingNetWork under continuous future work from estimatedDepartureAt=earliestGoalAt+unrecordedExpectedBreak when forecasts are applicable. Both SHALL expose assumptions.

#### Scenario: No rest yet
- **WHEN** 11:30開始、休憩未記録、現在11:31、標準休憩60分
- **THEN** 実働残り6時間59分、最短達成18:30、休憩込みの退勤見込み19:30を別表示する

#### Scenario: Break completed
- **WHEN** 11:30開始、12:00〜13:00休憩、現在18:10
- **THEN** 最短達成と休憩込み退勤見込みはいずれも19:30となる

#### Scenario: Break ongoing
- **WHEN** 休憩中で終了時刻が不明
- **THEN** 両方の将来時刻を未確定とし、残り実働時間だけ表示する

### Requirement: Actual achievement supersedes plans
The system SHALL calculate a threshold crossing from validated recorded intervals, distinguishing verified achievement from an unreviewed provisional crossing.

#### Scenario: No break taken
- **WHEN** 11:30開始から無休憩で18:30になる
- **THEN** 実績として7時間達成を18:30に表示し、19:30の未達カウントダウンを残さない

#### Scenario: Later break
- **WHEN** 18:30達成後18:40に休憩へ入る
- **THEN** 実際の達成時刻18:30を保持し新たな未達通知を生成しない

### Requirement: Freeze on exit
The system SHALL freeze actual duration, achievedAt and reference delta after clock-out. It SHALL NOT keep incrementing closed workdays from wall time.

#### Scenario: Historical view
- **WHEN** 17:00退勤した日の履歴を21:00に開く
- **THEN** 実働・超過・基準定時差分は17:00に確定した値を表示する

### Requirement: Rounding and clock anomalies
The system SHALL use absolute seconds for calculations, ceil positive remaining time to minute displays and floor completed surplus; it SHALL reject negative durations or detect backward clock anomalies.

#### Scenario: One second left
- **WHEN** 実働25199秒である
- **THEN** 表示はあと1分、実働25200秒で達成とする

#### Scenario: Clock rewound
- **WHEN** 15:00開始後にOS時計が14:50へ戻る
- **THEN** 負の実働を計算せず、時刻異常の確認表示とする

### Requirement: Planned departure is hypothetical
The system SHALL compare a user-entered future departure Instant against projected net work and clearly mark its shortfall/surplus as a scenario, never an attendance record.

#### Scenario: 20:00 planned
- **WHEN** 11:30開始、12:00〜13:00休憩、退勤予定20:00、追加休憩なし
- **THEN** 見込み実働450分、日次目標超過見込み30分を予定として表示する

### Requirement: Provisional versus confirmed achievement
The system SHALL distinguish provisional from confirmed recorded achievement when unresolved intervals can affect goal attainment. It SHALL report attainment as certain if the verified lower bound alone meets the target, but SHALL NOT claim an exact crossing time if unresolved spans could move that time.

#### Scenario: Threshold includes unverified sleep
- **WHEN** 60分の未確認スリープを含む勤務記録が7時間相当の経過に到達する
- **THEN** 達成確定を表示せず「計算上の目標到達・要確認」とする

#### Scenario: Uncertainty resolved
- **WHEN** 利用者が要確認区間を訂正または明示確認する
- **THEN** 最初の累積実働420分の到達時刻を再計算し、確定可否を更新する

### Requirement: Ended workday remains frozen
The system SHALL display a completed workday as achieved or shortfall from the final recorded net work. It SHALL NOT continue a goal countdown after clock-out.

#### Scenario: Clock out with shortfall
- **WHEN** 実働6時間30分で退勤が確定する
- **THEN** 「日次目標まで30分不足」と固定表示し未来の到達予測は表示しない

#### Scenario: Explicit resume
- **WHEN** 実働6時間30分で退勤した勤務日を利用者が明示的に再開する
- **THEN** 残り30分として新たな最短目標時刻を計算する

### Requirement: Bounded worked time under unresolved anomalies
The system SHALL compute a nonnegative lower bound from verified recorded work spans and an upper bound by additionally including unresolved spans that may represent work. A goal is definitely not reached when upper bound is below target, possibly reached when lower bound is below target but upper bound meets target, and definitely reached in the user-recorded interval sense when lower bound meets target. An exact achievement Instant SHALL be shown only if invariant under all valid resolutions of uncertain spans.

#### Scenario: Possible achievement after unreviewed sleep
- **WHEN** 11:30に開始し16:30〜17:30が未確認、現在18:30まで勤務記録が続く
- **THEN** 確認済み6時間・上限7時間とし、目標は到達可能性あり・要確認、確定時刻は表示しない

#### Scenario: Goal certainly reached despite unreviewed sleep
- **WHEN** 同じ勤務記録が19:30まで継続し、16:30〜17:30だけが未確認
- **THEN** 確認済み7時間・上限8時間となり、7時間到達済みだが正確な到達時刻は18:30〜19:30の範囲として表示する

#### Scenario: Correct uncertain hour to break
- **WHEN** 上記の未確認16:30〜17:30を休憩へ訂正する
- **THEN** 実働の下限と上限は一致し、最初の7時間到達時刻は19:30となる

#### Scenario: Confirm uncertain hour as working
- **WHEN** 上記の未確認16:30〜17:30を勤務継続として確認する
- **THEN** 実働の下限と上限は一致し、最初の7時間到達時刻は18:30となる

#### Scenario: Anomaly occurs after goal was achieved
- **WHEN** 11:30開始、18:30に7時間到達後、19:00〜20:00に未確認区間が発生する
- **THEN** 18:30の到達時刻は維持し、未確認区間はその後の超過実働にのみ影響する

### Requirement: Forecast unavailable when bounds diverge
The system SHALL not present a single exact future target Instant when unresolved spans make multiple target times possible. It SHALL display remaining-work bounds and a review prompt until uncertainty is resolved.

#### Scenario: Uncertain time changes remaining
- **WHEN** 記録上の実働が6時間で、そのうち30分が未確認である
- **THEN** 実働の下限5時間30分・上限6時間、残り実働は60〜90分の範囲と表示し、単一の確定退勤見込みを表示しない

### Requirement: Forecast override is independent
The system SHALL include only explicitly forecast future break seconds when producing an estimated departure and SHALL NOT write forecast overrides into historical work or break intervals.

#### Scenario: Thirty-minute remaining break
- **WHEN** 11:30開始、未取得休憩60分で今後の休憩見込みだけを30分に変更する
- **THEN** 最短達成は18:30、休憩込み見込みは19:00、休憩実績は0分となる

### Requirement: Non-work gaps do not satisfy planned rest
The system SHALL exclude explicitly classified non-working gaps from both actual work and recorded break; unlike an actual break they SHALL not reduce the default remaining expected rest.

#### Scenario: One-hour non-working gap before the target
- **WHEN** 11:30出社、16:30〜17:30を非勤務ギャップと記録し17:30時点で休憩実績0分である
- **THEN** 実働5時間、最短達成19:30、既定の予定休憩込み退勤見込み20:30となる

#### Scenario: Same interval classified as an actual break
- **WHEN** 同じ16:30〜17:30を休憩として記録する
- **THEN** 実働5時間、休憩実績60分、最短達成と退勤見込みは19:30となる

### Requirement: Non-destructive leave-at what-if projection
The system SHALL calculate a hypothetical net-work result for a candidate departure Instant without modifying the canonical workday, actual end time, or persisted plannedDepartureAt. A user SHALL explicitly confirm if they want to save a candidate as a plan. The preview SHALL account for future planned rest and unresolved recorded intervals.

#### Scenario: Leave at 19:00 after recorded break
- **WHEN** 11:30開始、12:00〜13:00休憩済み、18:10現在で19:00退勤を試算する
- **THEN** 19:00の想定実働は6時間30分、日次目標まで30分不足と表示する

#### Scenario: Leave at 20:00 after recorded break
- **WHEN** 同じ勤務日で20:00退勤を試算する
- **THEN** 想定実働7時間30分、日次目標を30分超過すると表示する（正式残業認定ではない）

#### Scenario: Cancel hypothetical departure
- **WHEN** 19:00退勤の試算画面を閉じる
- **THEN** 記録済み実働・退勤予定・通知計画と勤務日revisionは変わらない

#### Scenario: Hypothetical departure with future break
- **WHEN** 11:30開始、休憩実績なし、残り予定休憩60分で19:00退勤を試算する
- **THEN** 想定実働6時間30分、目標不足30分と表示し、その根拠に将来休憩60分を明記する

#### Scenario: Uncertain past work in leave-at preview
- **WHEN** 過去の未確認時間がある勤務日で19:00退勤を試算する
- **THEN** 想定実働と過不足を範囲で示し、単一の確定値として表示しない
