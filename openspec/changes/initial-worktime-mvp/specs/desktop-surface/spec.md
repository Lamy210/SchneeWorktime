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

### Requirement: Show forecast and evidence states
The system SHALL clearly label confirmed worked time, forecast departure and unverified time, and SHALL replace active countdown with achieved or shortfall when a workday ends.

#### Scenario: Unverified work period
- **WHEN** スリープ由来の要確認区間を含む実働を表示する
- **THEN** 「要確認」ラベルを出し確定達成時刻として扱わない

#### Scenario: Early clock-out
- **WHEN** 実働6時間30分で退勤する
- **THEN** パネルに「30分不足」と終了時刻を示しタイマーを停止する

### Requirement: Primary glance view exposes prediction assumptions
The system SHALL make the break-adjusted estimated departure the primary planned time for active workdays with known forecasts, and SHALL separately label earliest goal, actual worked duration and any reference-time delta.

#### Scenario: Late clock-in with no recorded break
- **WHEN** 11:30出社でまだ休憩実績がなく標準休憩60分である
- **THEN** 「退勤見込み19:30（休憩予定60分込み）」と「最短7時間18:30」を区別する

#### Scenario: Current forecast overridden
- **WHEN** 利用者が残りの休憩予定を30分に変更する
- **THEN** 19:00の退勤見込みに予定条件が表示され、実際の休憩実績は変更されない

### Requirement: Show uncertainty as an interval
The system SHALL expose work-time lower/upper bounds and goal achievement window when unresolved spans can change elapsed work. It SHALL not display uncertain values using the same confirmed label and typography.

#### Scenario: Goal is certain but completion instant is uncertain
- **WHEN** 確認済み実働7時間、未確認時間1時間が存在する
- **THEN** 「7時間以上達成・到達時刻は要確認」を表示する

#### Scenario: Goal might or might not be achieved
- **WHEN** 実働下限6時間、上限7時間のとき
- **THEN** 「7時間到達の可能性あり・要確認」と表示し、達成確定を表示しない

### Requirement: Review UI offers distinct uncertainty resolutions
The system SHALL offer separate explicit review actions for continued work, an actual unpaid break and a non-working gap, and SHALL preview the resulting work and estimated departure differences before saving.

#### Scenario: User resolves a sleep interval
- **WHEN** スリープ由来の要確認区間を訂正画面で開く
- **THEN** 「勤務継続」「休憩」「非勤務ギャップ」を区別して選択でき、保存前に実働と退勤見込みへの影響を確認できる
