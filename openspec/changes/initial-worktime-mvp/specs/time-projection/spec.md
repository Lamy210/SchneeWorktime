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
The system SHALL keep arithmetic elapsed work separate from confirmed recorded achievement if a contributing interval remains unverified. It SHALL NOT present an unverified threshold crossing as confirmed attainment.

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
