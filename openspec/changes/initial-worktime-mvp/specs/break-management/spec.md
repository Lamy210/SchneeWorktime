# Spec Delta

## Purpose
休憩の取得予定と記録済み実績を区別し、実働時間に休憩を誤って加減算しない。取得中の休憩が未終了なら将来の確定時刻を断定しない。

## ADDED Requirements

### Requirement: Separate forecast from actual
The system SHALL treat the default 60-minute break as a future projection assumption until an actual break is recorded; it SHALL NOT deduct assumed rest from actual worked duration.

#### Scenario: No recorded break
- **WHEN** 11:30から休憩なしで勤務し12:30となる
- **THEN** 実働は60分であり、予測休憩60分を実績に算入しない

#### Scenario: Completed break
- **WHEN** 12:00〜13:00の休憩を開始・終了で記録する
- **THEN** 実働はその60分間増えず、実績休憩が60分となる

### Requirement: Multiple breaks
The system SHALL support multiple nonoverlapping break intervals within one workday, including touching closed boundaries.

#### Scenario: Extra break
- **WHEN** 12:00〜13:00と16:00〜16:30の休憩を記録する
- **THEN** 休憩実績90分とし、計算は30分遅延する

#### Scenario: Adjacent intervals
- **WHEN** 12:00〜13:00と13:00〜13:30の休憩を記録する
- **THEN** 境界一致を重複とみなさず90分を保持する

### Requirement: Open break has unknown end
The system SHALL freeze net work while a break is active and SHALL not provide an exact future goal time until the return time is known.

#### Scenario: Unknown break end
- **WHEN** 15:00に休憩開始して終了予定がない
- **THEN** 実働は停止し、時刻ベースの目標/退勤予測は未確定と表示する

#### Scenario: Break completed
- **WHEN** 15:00に開始した休憩を15:20に終了する
- **THEN** 実績20分を加え、予測と通知を再計算する

### Requirement: Record advisory
The system SHALL offer a nonbinding review hint when recorded breaks look insufficient relative to recorded work, without making a legal violation claim or fabricating a break.

#### Scenario: Seven hours without break
- **WHEN** 7時間の勤務実績があるが休憩記録は0分である
- **THEN** 目標達成を維持しつつ休憩記録の確認を促す

### Requirement: Forecast rest must stop delaying achieved work
The system SHALL expose remaining expected rest as a forecast assumption only while the daily target is not yet achieved, and SHALL not deduct any unrecorded break from actual work.

#### Scenario: Target achieved without a break
- **WHEN** 11:30から休憩なしで18:30に7時間の実働を記録する
- **THEN** 目標達成と表示し、未取得60分によって到達表示を19:30に遅らせない

#### Scenario: Recorded rest exceeds assumption
- **WHEN** 標準休憩60分に対して休憩実績が90分となる
- **THEN** 残り予定休憩を0分とし、マイナス30分の予定休憩を作らない
