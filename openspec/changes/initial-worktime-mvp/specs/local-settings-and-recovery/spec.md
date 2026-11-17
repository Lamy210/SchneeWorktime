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

#### Scenario: Corrupt store or settings
- **WHEN** ストアまたは設定が破損して現行世代の正常バックアップがある
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
The system SHALL commit canonical workday intervals, correction audit and per-day revision within the app-wide store transaction. It SHALL not expose a new workday revision when its corresponding audit record has not been durably committed.

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

### Requirement: Transaction covers all workdays
The system SHALL serialize all mutations across processes and commit the complete workday catalog, active identifier, per-day revisions and audit in one atomic store transaction. It SHALL validate at most one active workday and nonoverlap globally before commit. Recovery SHALL never choose a new active workday by guessing.

#### Scenario: Concurrent clock-in across separate windows or processes
- **WHEN** 未開始状態から2つの操作が異なる勤務日を同時作成しようとする
- **THEN** 片方のみ成功し、他方は競合を返す。activeは最大1件

#### Scenario: Crash during active pointer change
- **WHEN** 勤務日作成または再開の保存中にアプリが異常終了する
- **THEN** カタログ・active ID・監査が一致する旧または新の完全な状態を復元する

#### Scenario: Invalid backup with two active days
- **WHEN** 復元候補が2つのactive勤務日を含む
- **THEN** 自動採用せず復旧を保留する

### Requirement: Erase is a recovery boundary
The system SHALL serialize erasure with ordinary writes, invalidate all pre-erase pending edits, and prevent automatic restoration of erased generations. It SHALL cancel app-owned pending work reminders after erase. It SHALL report incomplete deletion rather than claiming success.

#### Scenario: Crash during history erase
- **WHEN** 全削除確定後にバックアップ削除途中で異常終了する
- **THEN** 削除済み世代を自動復元せず削除の続行または失敗を明示する

#### Scenario: Stale edit after erase
- **WHEN** 全削除以前の訂正画面が保存を試みる
- **THEN** 旧世代の更新を拒否し削除した勤務日を復活させない

### Requirement: Compare and swap the durable snapshot
The storage adapter SHALL read the stored epoch and revision inside an exclusive writer transaction before replacing the complete snapshot payload. A mismatch SHALL reject the write. A logical reset SHALL replace the epoch and clear the payload atomically. Physical erasure and backup fencing remain separate requirements.

#### Scenario: Stale independent writer
- **WHEN** 二つの接続が同じ保存版を読み、先行接続が保存する
- **THEN** 後続の古い版による保存を拒否し先行のpayloadを維持する

#### Scenario: Logical reset boundary
- **WHEN** 保存済みpayloadの論理リセット後、削除前のepochで保存する
- **THEN** 拒否し、空の新世代を維持する

### Requirement: Separate first creation from normal recovery
The storage adapter SHALL allow database creation only on explicit trusted first initialization. Ordinary reopening SHALL NOT recreate a missing database. An existing uninitialized or unsupported schema SHALL fail rather than being silently replaced.

#### Scenario: Missing or empty existing database
- **WHEN** 通常起動時にDBが消失している、または既存DBが空である
- **THEN** エラーを返し新規空DBへの置換を行わない

### Requirement: Reconstruct the catalog through validated journal replay
The storage coordinator SHALL encode a versioned journal of accepted operations, replay each through the domain invariants on load, and reject malformed, unsupported, future or impossible histories without overwriting the saved bytes. The durable revision SHALL equal the number of accepted persisted events.

#### Scenario: Reopen with recorded review
- **WHEN** 出社、観測、部分休憩訂正、退勤を保存し再起動する
- **THEN** UUID・区間・状態・観測・監査・各世代を同一内容として復元する

#### Scenario: Invalid journal
- **WHEN** 未開始勤務の休憩開始、破損JSONまたは現在より未来の記録を復元する
- **THEN** エラーとし原本を上書きしない

### Requirement: Commit before publishing canonical mutations
The repository SHALL return changed canonical state only after the durable store accepts the expected epoch and revision. A review proposal SHALL carry its original store version as well as its domain version. Duplicate observations SHALL not append a journal event or advance the durable version.

#### Scenario: Review from a prior epoch
- **WHEN** 論理リセット後に同じ勤務ID・revision・観測世代が再現されても削除前の訂正案で保存する
- **THEN** 保存epochの相違で拒否し現データを維持する

#### Scenario: Duplicate durable observation
- **WHEN** 既に受理した観測範囲を同じ保存版で再送する
- **THEN** payloadの追加保存・store revisionの更新を行わない
