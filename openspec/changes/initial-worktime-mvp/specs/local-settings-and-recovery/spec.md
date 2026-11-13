# Spec Delta

## Purpose
勤務記録と個人設定をクラウド不要で安全に保存し、破損やアプリ再起動でも事実と予測を混同せず復旧・エクスポートできるようにする。

## ADDED Requirements

### Requirement: Local-first private storage
The system SHALL store attendance records and configuration locally and SHALL NOT send workplace time data or telemetry to a remote server.

#### Scenario: Offline
- **WHEN** ネットワークを切断して一週間使用する
- **THEN** 出退勤/休憩/計算/履歴閲覧が継続できる

### Requirement: Durable validated commits
The system SHALL persist versioned, validated records atomically with revision control, preserving the last known-good state on failure.

#### Scenario: Crash during write
- **WHEN** 記録書き込み中にアプリが異常終了する
- **THEN** 次回起動で完了済みの整合データを復元し、部分記録で上書きしない

#### Scenario: Bad JSON
- **WHEN** 設定ファイルが破損して正常バックアップがある
- **THEN** 破損原本を保護して復旧選択肢を示し、空データで上書きしない

### Requirement: Explicit correction audit
The system SHALL record historical modifications with timestamp, before/after values and a revision, without silently replacing prior information.

#### Scenario: Correction
- **WHEN** 出社11:30を11:20へ修正する
- **THEN** 訂正の前後、修正日時とrevisionを記録し、予測を再計算する

### Requirement: Export and erase
The system SHALL support explicit JSON/CSV export and confirm before destructive local-history deletion.

#### Scenario: Export
- **WHEN** ユーザーが全履歴エクスポートを選ぶ
- **THEN** 時刻帯・実働区間・休憩区間・訂正revisionを保持したファイルを出力する

#### Scenario: Erase
- **WHEN** ユーザーが履歴全削除を選ぶ
- **THEN** 確認の前には削除しない

### Requirement: Rebuild schedule after interrupted commit
The system SHALL derive intended future notifications from last validated committed workday state during startup rather than trusting the previously cached pending request list.

#### Scenario: Persisted event without scheduled notification
- **WHEN** 状態保存直後にアプリが異常終了し通知予約が未更新となる
- **THEN** 次回起動で保存済みrevisionを基準に将来の通知を再同期する

### Requirement: Preserve provenance of uncertainty correction
The system SHALL record the original unverified span, confirmation or correction action and revision without deleting original history silently.

#### Scenario: Resolve a sleep interval
- **WHEN** スリープ由来の要確認区間を休憩に訂正する
- **THEN** 原本の時刻と訂正内容を追跡できる

### Requirement: Export only on explicit destination
The system SHALL export work history only to a user-confirmed local destination and SHALL keep canonical records unchanged if destination selection is cancelled.

#### Scenario: Export cancelled
- **WHEN** エクスポートの保存先選択をキャンセルする
- **THEN** 出力を作成せず勤務履歴を変更しない
