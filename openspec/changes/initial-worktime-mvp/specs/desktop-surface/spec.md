# Spec Delta

## Purpose
macOSデスクトップに常駐する非侵襲的な半透明表示とメニューバー操作を提供し、ユーザーが必要に応じて表示・非表示を切り替えられるようにする。

## ADDED Requirements

### Requirement: Read-only glance surface
The system SHALL display the state, actual work, remaining work, earliest goal, break-adjusted departure estimate and reference delta with explicit labels in a lightweight surface.

#### Scenario: Active work
- **WHEN** 11:30出社で18:10現在、12:00〜13:00休憩済み
- **THEN** 実働5時間40分、残り1時間20分、見込み19:30を区別して表示する

#### Scenario: Ended
- **WHEN** 勤務終了後にパネルを表示する
- **THEN** カウントダウンでなく実績と終了時刻を表示する

### Requirement: Controllable placement
The system SHALL allow move, opacity, panel visibility and optional top-most behavior, and SHALL recover an off-screen position after monitor configuration changes.

#### Scenario: Hidden glass
- **WHEN** パネルを隠して勤務を継続する
- **THEN** 記録と通知計画は継続しメニューバーから再表示可能

#### Scenario: Lost external monitor
- **WHEN** 外部モニター切断後にパネルを表示する
- **THEN** 使用可能な画面の範囲へ配置を修復する

### Requirement: Accessible interaction
The system SHALL support keyboard navigation, VoiceOver labels, sufficient contrast and reduced-motion settings for all primary commands.

#### Scenario: VoiceOver
- **WHEN** VoiceOverで勤務開始と休憩操作に移動する
- **THEN** 操作名と現在状態が読み上げ可能である

### Requirement: Low power rendering
The system SHALL derive displayed countdown from absolute time without persisting each tick and SHALL avoid continuous panel redraw while hidden.

#### Scenario: Panel hidden
- **WHEN** 長時間パネルを非表示にする
- **THEN** 非表示中に毎秒描画を要求せず、再表示時に現在時刻から再計算する
