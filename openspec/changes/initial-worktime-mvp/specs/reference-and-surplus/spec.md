# Spec Delta

## Purpose
勤務日ごとの基準終業時刻と日次目標の差分を独立して表示し、フレックス清算期間や法定残業の判定と誤認されないようにする。

## ADDED Requirements

### Requirement: Independent reference
The system SHALL support an editable optional wall-clock reference end (default 18:00) anchored to the logical workday start-date and captured timezone.

#### Scenario: Reference passed
- **WHEN** 18:00基準、勤務継続中の18:10
- **THEN** 基準終業から10分経過と表示し、残業確定とは表現しない

#### Scenario: Before reference
- **WHEN** 基準18:00の日に17:00退勤
- **THEN** 60分早く終了と固定表示する

#### Scenario: Reference precedes clock-in
- **WHEN** 21:00出社で同日18:00が基準終業時刻
- **THEN** 参考時刻は開始前として不適用扱いにし、過去分の通知を発火しない

### Requirement: Daily target surplus not statutory overtime
The system SHALL calculate and label daily goal surplus independently of reference clock time, and SHALL not assert lawful overtime or pay from this alone.

#### Scenario: Reference exceeds before goal
- **WHEN** 11:30出社・60分休憩で18:10現在
- **THEN** 基準10分超過かつ日次目標超過0分を同時表示する

#### Scenario: Target exceeded
- **WHEN** 同条件で20:00現在も勤務中
- **THEN** 基準120分超過かつ日次目標超過30分を表示する

### Requirement: Profile snapshot stability
The system SHALL snapshot target, break assumption, reference time and reference timezone for each workday; changing global settings SHALL by default affect subsequent workdays, unless the user explicitly confirms updating the active workday.

#### Scenario: Settings changed midshift
- **WHEN** 勤務中に通常定時を18:00から17:30へ変更する
- **THEN** 既存の勤務日は変更確認なしでは元の18:00を保持する

### Requirement: Reference clock and rest are independent
The system SHALL compare reference time using the workday's captured date and timezone without adding or subtracting work time, even while the user is on break.

#### Scenario: Reference reached during break
- **WHEN** 基準18:00の勤務日で17:45〜18:15に休憩を記録する
- **THEN** 基準18:00を過ぎたことだけを表示し、休憩中の実働を増加させない

#### Scenario: Timezone changes during shift
- **WHEN** 勤務開始後にOSのタイムゾーンが変わる
- **THEN** 勤務日開始時点のタイムゾーンに対応した基準Instantを維持する
