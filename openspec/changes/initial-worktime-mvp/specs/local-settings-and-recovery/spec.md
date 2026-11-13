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

### Requirement: Save each workday and its audit atomically
The system SHALL commit the canonical workday intervals, correction audit and revision as one validated atomic unit per workday. It SHALL not expose a new workday revision when its corresponding audit record has not been durably committed.

#### Scenario: Crash between revision and audit write
- **WHEN** 訂正中にアプリが異常終了する
- **THEN** 次回起動で勤務日と訂正履歴が同一の正常revisionとして復旧し、不整合な部分書き込みを採用しない

#### Scenario: Concurrent conflicting correction
- **WHEN** 同一勤務日の旧revisionを持つ2画面が異なる訂正を保存しようとする
- **THEN** 先に成功したrevisionを保持し、後からの競合更新を明示的に拒否する

### Requirement: App liveness markers are not attendance
The system SHALL use app lifecycle observation markers only to identify unobserved time after restart. These markers SHALL NOT be counted as work or break records and SHALL NOT modify the workday revision without a user action.

#### Scenario: Process restarted without clean shutdown
- **WHEN** working状態のままアプリが強制終了し、その後起動する
- **THEN** 最後の観測時刻から再起動までを要確認として提示し、liveness markerを実働に加算しない

#### Scenario: Liveness metadata unavailable
- **WHEN** 最終観測メタデータが欠落した状態で未終了勤務を復元する
- **THEN** 勤務開始から再起動時点までの不確実性を明示し、静かに勤務確定を行わない

### Requirement: Complete app-owned history deletion
The system SHALL include canonical workday records, correction audit, app-owned backups and app-owned diagnostic attendance data in an explicit destructive local erase, while warning that user-exported files and system backups remain outside app control.

#### Scenario: Confirm local erase
- **WHEN** 利用者がローカル履歴の全削除を明示確認する
- **THEN** アプリ管理下の本体記録・訂正ログ・バックアップを削除対象とし、完了/失敗の結果を表示する

#### Scenario: User exports remain
- **WHEN** アプリの全履歴を削除するが、利用者が過去に別フォルダーへエクスポートしたファイルがある
- **THEN** アプリは外部ファイルを削除せず、削除対象外であることを事前に案内する
