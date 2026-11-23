# Spec Delta

## Purpose
勤務開始から終了までの連続した記録と、後からの訂正を、明示操作と矛盾しない状態遷移として管理する。日跨ぎと再開に耐える一意の勤務日を提供する。

## ADDED Requirements

### Requirement: Explicit transition control
The system SHALL require user intent for clock-in, break start/end, clock-out and resume. It SHALL NOT infer working from computer unlock or screen activity.

#### Scenario: Clock in
- **WHEN** 未開始の勤務日に11:30で出社操作する
- **THEN** workingになり、11:30開始の開いた勤務区間が1つ記録される

#### Scenario: Duplicate action
- **WHEN** 勤務中に出社操作が重複する
- **THEN** 別の勤務日/区間を増やさず、重複操作として扱う

#### Scenario: Clock out
- **WHEN** workingで17:00に退勤する
- **THEN** 開いている区間を17:00で閉じてendedとなる

### Requirement: One logical active workday
The system SHALL allow at most one active logical workday and SHALL retain its identifier and start-date association across midnight.

#### Scenario: Cross-midnight
- **WHEN** 21:00開始の勤務を翌日01:00まで継続する
- **THEN** 日付を跨いでも開始日の同じworkday IDを使用し、自動で勤務を分割しない

#### Scenario: Second active day
- **WHEN** 未終了の勤務が存在する状態で新しい出社を操作する
- **THEN** 重複する勤務日を作らず、既存勤務の確認を求める

### Requirement: Resume after clock-out
The system SHALL resume an ended workday only by explicit action and SHALL exclude gaps between end and resume from worked duration.

#### Scenario: Resume
- **WHEN** 17:00退勤した日の18:00に明示的に再開し18:30に退勤する
- **THEN** 元の勤務日に30分の新しい区間を追加し、17:00〜18:00は勤務に含めない

### Requirement: Validate historical corrections
The system SHALL validate all stored intervals as a whole and reject impossible, overlapping, stale-revision or zero-length corrections without changing canonical data.

#### Scenario: Overlap
- **WHEN** 訂正によって勤務区間が休憩と重なる
- **THEN** 保存を拒否し、以前の記録と通知計画を維持する

#### Scenario: Stale edit
- **WHEN** 古いrevisionから履歴を書き戻そうとする
- **THEN** 競合として拒否し、後勝ち上書きをしない

### Requirement: Uncertain continuity
The system SHALL flag potentially unverified time after sleep, system clock jump or unexpectedly long open sessions; it SHALL NOT auto-create a break or clock-out.

#### Scenario: Wake
- **WHEN** 勤務中に90分スリープして復帰する
- **THEN** 勤務の推定を行わず記録確認を促し、状態を勝手に変更しない

#### Scenario: Long open shift
- **WHEN** 16時間以上の未終了勤務を復元する
- **THEN** 要確認を提示し、自動退勤を行わない

### Requirement: Explicit clock-out from break
The system SHALL require explicit confirmation for clock-out during an open break and SHALL close that break at the selected end Instant without inventing an additional work interval.

#### Scenario: Confirm break-end clock-out
- **WHEN** 17:00から休憩中に17:15の退勤を選択し確認する
- **THEN** 休憩を17:15で閉じ、勤務区間を追加せずendedとなる

#### Scenario: Cancel break-end clock-out
- **WHEN** 休憩中の退勤確認をキャンセルする
- **THEN** 休憩状態と勤務実績は変更されない

### Requirement: Unverified elapsed spans
The system SHALL flag active work intervals intersecting a detected sleep, clock anomaly or unexpectedly long interruption as unverified until the user explicitly confirms or corrects them. It SHALL NOT silently generate a break or clock-out.

#### Scenario: Wake during work
- **WHEN** workingのまま16:30〜17:30にMacがスリープして復帰する
- **THEN** 区間を要確認として保持し、自動休憩・自動退勤を行わない

#### Scenario: Confirm actual work
- **WHEN** 利用者が要確認区間を勤務継続として明示確認する
- **THEN** 該当区間を確認済みとし、目標達成と通知を再評価する

#### Scenario: Correct sleep as break
- **WHEN** 要確認の16:30〜17:30を休憩へ訂正する
- **THEN** 実働から60分除外し、見込みと未来通知を再計算する

### Requirement: Workday identity across midnight
The system SHALL bind continuation and resumption to a stable workday UUID rather than local calendar-day equality. It SHALL allow explicitly resuming the same ended workday after midnight if no later workday exists and the resulting intervals do not overlap another workday.

#### Scenario: Resume after midnight
- **WHEN** 21:00に開始して翌日00:30に退勤した勤務記録を、翌日01:00に明示的に再開する
- **THEN** 開始日の勤務記録IDを再利用し、00:30〜01:00を実働へ加算しない

#### Scenario: Later workday already exists
- **WHEN** 後続の勤務日が記録済みである古い勤務日を再開しようとする
- **THEN** 新しい実働区間の追加を拒否し、既存履歴の訂正導線を提示する

### Requirement: Recover uncertain app downtime
The system SHALL NOT equate application termination with clock-out. It SHALL flag an active session's unobserved period after unexpected app termination, system shutdown or restart as an uncertain span for explicit confirmation or correction.

#### Scenario: Quit without clock-out
- **WHEN** 16:00にworking状態でアプリを終了し17:00に再起動する
- **THEN** 勤務日の状態を維持し、未観測区間を要確認として提示し、退勤を捏造しない

#### Scenario: Restart while break was active
- **WHEN** onBreak状態でアプリが終了して30分後に再起動する
- **THEN** 開いた休憩が継続中として復元され、ユーザーが休憩終了時刻を訂正できる

#### Scenario: Screen lock but app remains active
- **WHEN** Macの画面のみをロックしアプリが継続稼働する
- **THEN** ロックだけを理由に休憩や退勤を自動生成しない

### Requirement: Prevent actual events in the future
The system SHALL accept actual clock-in, break and clock-out instants only at or before a trusted current Instant; future times are planning data, not attendance events.

#### Scenario: Future correction entered as actual
- **WHEN** 現在15:00なのに実績の退勤を18:00へ訂正しようとする
- **THEN** 実績としての保存を拒否し、将来の退勤予定として別操作を案内する

### Requirement: Three-way uncertain-time resolution
The system SHALL allow explicitly resolving an uncertain interval as worked, an actual unpaid break, or a non-working gap. It SHALL NOT count a non-working gap toward recorded rest or worked time, and SHALL preserve the chosen classification in the correction audit.

#### Scenario: Resolve as non-working gap
- **WHEN** 16:30〜17:30の未確認区間を「非勤務ギャップ」として訂正する
- **THEN** その60分を勤務から除外し、休憩実績にも加算しない

#### Scenario: Reclassify non-working gap as actual break
- **WHEN** 訂正済みの非勤務ギャップをさらに休憩へ訂正する
- **THEN** 勤務実績は増やさず、休憩実績に60分加え、訂正の履歴を保存する

### Requirement: Fast manual clock-in with past-time correction
The system SHALL let a user clock in using the current time by default or explicitly choose an earlier actual start Instant. It SHALL preserve the user-selected actual start time and reject future or overlapping work intervals.

#### Scenario: Enter earlier clock-in after opening the app
- **WHEN** 11:45にアプリを起動し、この勤務日の出社時刻を11:30に指定して確定する
- **THEN** 11:30から実働を計算し、11:45から15分間の勤務実績として扱う

#### Scenario: Start now with quick command
- **WHEN** 未開始の勤務日にメニューバーから「今から出社」を選択する
- **THEN** 現在のInstantを開始時刻として1つの勤務区間を記録する

#### Scenario: Reject future actual clock-in
- **WHEN** 現在11:45なのに当日12:00の出社時刻を実績として確定しようとする
- **THEN** 実績の保存を拒否し、必要なら将来の予定として別入力するよう案内する

### Requirement: Reject zero-length closed intervals
The system SHALL accept a zero-elapsed open interval immediately after creation, but SHALL reject a clock-out or break transition that would close it at the same Instant or earlier. A rejected command SHALL leave the whole catalog, revisions and notifications unchanged.

#### Scenario: Close on same second
- **WHEN** 11:30:00に出社し同じ秒に退勤又は休憩開始を操作する
- **THEN** ゼロ長の閉区間を生成せず、元のworking状態を保持して再操作を案内する

### Requirement: Append-only ordinary workday creation
The system SHALL permit a new ordinary clock-in only when there is no active day, the UUID is unused, and its start is at or after the latest recorded end. Earlier historical insertion or alteration SHALL use explicit correction, not the ordinary clock-in command.

#### Scenario: Backdated start intersects or precedes newer history
- **WHEN** 最新の勤務日が17:00に退勤済みなのに通常出社で16:59を入力する
- **THEN** 拒否し、既存履歴を変更しない

#### Scenario: New day at touching boundary
- **WHEN** 最新の終了時刻と同じInstantに新しいUUIDで明示出社する
- **THEN** 半開区間として重複せず、新しい勤務日の開区間を作成する

### Requirement: Catalog revision checks on command
The system SHALL validate each explicit mutation against the expected application-wide catalog revision before applying it. A stale command or failed transition SHALL change neither a workday nor the global revision. The durable adapter SHALL revalidate the store epoch and revision within its transaction.

#### Scenario: Competing stale command
- **WHEN** 同じrevisionを読んだ二画面のうち最初の打刻が成功し、残った画面が旧revisionで操作する
- **THEN** 後続を競合拒否し、先行の記録のみ保持する

### Requirement: Clip valid observations to the recorded end
The system SHALL validate observation endpoints against the trusted current Instant. A valid observation spanning a historical clock-out SHALL be intersected with recorded work only; its portion after clock-out SHALL NOT invalidate the closed snapshot or count as work.

#### Scenario: Downtime spans a backdated clock-out
- **WHEN** 退勤実績17:00、現在18:00、未確認観測16:30〜17:30が存在する
- **THEN** 16:30〜17:00のみを勤務との交差として評価し、退勤以後の観測は実働計算に影響しない。現在より未来の観測端点は拒否する

### Requirement: Review exactly the selected uncertain work
The system SHALL accept a positive selected review range only when it lies within one effective work interval and is fully covered by the union of unresolved observations. It SHALL reject an uncovered, already resolved, future or empty range. Cross-interval selections SHALL be reviewed as separate ranges.

#### Scenario: Partial overlapping observations
- **WHEN** 未確認観測20〜50秒と40〜70秒を持つ勤務のうち30〜60秒を勤務として確認する
- **THEN** 確認部分だけを未確認から除外し、20〜30秒と60〜70秒を維持する

#### Scenario: Review through the current Instant
- **WHEN** 継続中の勤務の未確認末尾を実際の休憩として訂正する
- **THEN** 訂正した部分だけを休憩にし、現在時刻に新しい開いた勤務区間を残す。実績の退勤を生成しない

#### Scenario: Duplicate or uncovered review
- **WHEN** 解決済み又は未確認から外れる範囲を未確認レビューとして操作する
- **THEN** 拒否する。既存実績の再訂正は専用の訂正コマンドを使用する

### Requirement: Review preview preserves before and after evidence
The system SHALL derive the proposed intervals, remaining uncertainty, selected classification and review Instant without mutating the original evidence. The application SHALL revalidate the catalog revision and observation generation before committing the review and its audit atomically.

#### Scenario: Review then cancel
- **WHEN** 訂正案の計算後に保存せず閉じる
- **THEN** 原本・未確認範囲・revision・通知が変化しない

### Requirement: Version-fenced catalog review
The system SHALL associate review proposals with the selected workday, catalog revision and observation generation. It SHALL recompute the selected correction at save time and reject stale or changed proposals without modifying intervals, observations or audit. Accepted reviews SHALL update these together, retaining the day identity and state.

#### Scenario: Observation changes while reviewing
- **WHEN** 訂正案表示後、勤務revisionを変えず新しい観測が追加される
- **THEN** 旧観測世代の保存を拒否し最新状態から再確認を求める

#### Scenario: Review an earlier ended day
- **WHEN** 新しい勤務日がworkingの状態で以前のended勤務日を訂正する
- **THEN** 以前の記録だけを訂正し新しいactive勤務日とその区間を維持する

### Requirement: Do not resurrect explicitly resolved observation spans
The system SHALL reject stale observation writes and exclude ranges covered by observation reviews or recorded rest boundary correction audits for the same workday from newly received observations. A recorded clock-in or clock-out correction alone SHALL NOT resolve future observations. Duplicate covered observations SHALL be no-ops. Review evidence SHALL survive observation updates; only an explicit accepted correction may change the classification.

#### Scenario: Replay an already reviewed range
- **WHEN** 勤務確定した20〜70秒の観測が再送される
- **THEN** 未確認時間を復活させず観測世代を増やさない

#### Scenario: Newly received range partially overlaps reviewed range
- **WHEN** 20〜70秒を解決済みの勤務日へ10〜80秒の観測が追加される
- **THEN** 10〜20秒と70〜80秒だけを未確認の候補として保持する


### Requirement: Audited recorded clock-out correction
The system SHALL provide a non-mutating preview and explicit, version-fenced atomic commit for correcting an ended workday's final closed work interval. Invalid or stale corrections SHALL leave durable state unchanged. Accepted corrections SHALL preserve unrelated workday state and persist before/after audit evidence. Reminders SHALL be recomputed only from committed state.

#### Scenario: Shorten or extend recorded clock-out
- **WHEN** 09:00〜17:00の終了済み勤務について17:00を16:30又は17:30に訂正し、現在時刻が訂正後の時刻以降である
- **THEN** プレビューは原本を変更せず、明示確定で末尾の勤務区間のみ更新し、監査とjournalを原子的に保存する

#### Scenario: Respect subsequent workday
- **WHEN** 以前の退勤を後続勤務日の開始より後へ訂正する
- **THEN** 保存を拒否し、後続勤務日と全体の保存版を維持する。後続開始と一致する訂正は半開区間として許容する

#### Scenario: Reject unsupported or stale correction
- **WHEN** 末尾が休憩、未終了、未来、ゼロ長、未確認区間との交差、又は保存版が旧い訂正を確定する
- **THEN** 記録と監査を変更せず拒否する

#### Scenario: Preserve unrelated state during clock-out correction
- **WHEN** 終了済み勤務日の末尾勤務終了を明示確定する
- **THEN** 勤務日ID、捕捉profile、先行勤務・休憩区間、他勤務日、最新active IDは変更せず、訂正前後の監査を記録する

#### Scenario: Observe again after corrected clock-out
- **WHEN** 退勤を前倒しした勤務日を明示的に再開し、その後に前倒し範囲と交差する未確認観測が発生する
- **THEN** 退勤訂正の監査だけを理由に新しい未確認観測を抑制しない

#### Scenario: Cancel or reopen correction
- **WHEN** 訂正案を取り消す、又は保存後にアプリを再起動する
- **THEN** 取消時は保存版・通知を変更せず、保存済みの場合はjournal再生とバックアップで訂正結果・監査を保持する

### Requirement: Audited recorded clock-in correction
The system SHALL offer non-mutating preview and an explicitly confirmed, version-fenced atomic commit for correcting an ended workday's first closed work interval. It SHALL preserve unrelated workday state, reject invalid boundaries and store before/after interval and reference audit evidence. Captured timezone/reference values SHALL NOT be silently re-resolved using current rules; legacy unknown context remains unknown. Notifications SHALL reconcile only from committed state.

#### Scenario: Adjust first recorded start
- **WHEN** 09:00〜17:00の終了済み勤務の始業を同じ捕捉日の08:30又は09:30へ訂正する
- **THEN** 最初の勤務区間の開始のみを変更する案を提示し、後続の休憩・退勤・勤務日ID・目標を維持する

#### Scenario: Preserve captured reference
- **WHEN** 訂正が捕捉日を跨ぐ、参考終業の解決状態又はInstantを変える、又は捕捉timezoneの規則更新で異なる結果を生む
- **THEN** 初期対応範囲外として拒否し、参照情報を無断で再計算しない

#### Scenario: Protect previous workday and uncertainty
- **WHEN** 訂正が前勤務日の終了より前、未確認区間との交差、ゼロ長、未来、変更なし、既存の将来休憩anchorより後の始業、又は保存版・観測世代の変更に該当する
- **THEN** 保存を拒否する。前勤務日の終了と一致する境界は許容する

#### Scenario: Reject unsupported active-day or logical-date correction
- **WHEN** 現在activeの勤務日を始業訂正する、又は訂正によって勤務日の捕捉logical dateを再割当する
- **THEN** 初期対応範囲外として拒否し、他勤務日と捕捉参考時刻を維持する

#### Scenario: Preview history before explicit confirmation
- **WHEN** 始業訂正のプレビューを開く又はキャンセルする
- **THEN** 前後の実働と日・週・月の集計差を表示し、確定するまでjournal・監査・通知を変更しない

#### Scenario: Historical totals and durable replay
- **WHEN** 始業訂正を保存し再起動する
- **THEN** 訂正前後の始業と参照contextを監査に保持し、集計は訂正済みの実績開始Instantと選択された集計timezoneで算出する。別timezoneの集計期間を跨ぎ得ることを明示する

#### Scenario: Legacy reference remains unknown
- **WHEN** 捕捉参考情報を持たない旧勤務日の始業訂正を保存し再起動又はJSONから検証する
- **THEN** 訂正前後の参照contextは不明のまま維持し、現在timezoneや設定から補完しない

#### Scenario: Reject same-version but different source snapshot
- **WHEN** 同一epoch/revisionでも訂正案の元Journal bytesが現行DBと一致しない
- **THEN** 訂正を拒否し、現行の保存済みsnapshotと監査を変更しない

#### Scenario: Observe again after corrected clock-in
- **WHEN** 始業時刻の訂正後に勤務日を再開し、訂正区間に交差する観測を受信する
- **THEN** 始業訂正の監査だけを理由に新しい未確認観測を抑制しない
