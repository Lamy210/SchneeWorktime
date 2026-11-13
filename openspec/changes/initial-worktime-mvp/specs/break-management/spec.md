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

### Requirement: Separate remaining-rest plan from actual break
The system SHALL permit an optional nonnegative forecast-only override for future planned rest on the active workday without modifying recorded breaks or requiring a false completed-break entry. Clearing the override SHALL restore the profile-derived forecast.

#### Scenario: Plan shorter future break
- **WHEN** 11:30出社・休憩未取得で今後の休憩予定を60分から30分へ変更する
- **THEN** 最短実働達成18:30を維持し、休憩込み退勤見込みを19:00へ変更する

#### Scenario: Clear rest override
- **WHEN** 上記の30分予定をクリアする
- **THEN** 退勤見込みを既定の19:30に戻し、休憩実績は0分のままとする

#### Scenario: Break actually taken after shorter plan
- **WHEN** 30分の休憩予定を立てた後、実際の休憩を40分記録する
- **THEN** 実働計算には40分の実績を使用し、予定30分を実績に上書きしない

### Requirement: Recorded break classification
The system SHALL count explicitly recorded unpaid rest as zero work, and SHALL NOT invent paid-rest or other employer-specific compensation semantics in the MVP.

#### Scenario: Unpaid break interval
- **WHEN** 13:00〜13:45を休憩として記録する
- **THEN** 実働に45分加算せず、標準休憩60分との差は将来予測にのみ使用する

### Requirement: Future-rest override is consumed by actual breaks
The system SHALL interpret an active-day future-rest override as rest seconds still planned at the moment of entry, and SHALL reduce that balance by subsequently completed actual break time without becoming negative. It SHALL anchor the override to the recorded-break total at the time it was set.

#### Scenario: Actual break exceeds remaining override
- **WHEN** 休憩予定残り30分を設定した後40分の休憩実績を記録する
- **THEN** 休憩実績40分、今後の予定休憩0分となり、追加の予定休憩30分を二重計上しない

#### Scenario: Part of remaining override consumed
- **WHEN** 休憩予定残り30分を設定した後10分の休憩実績を記録する
- **THEN** 休憩実績10分、将来の予定休憩残り20分として計算する
