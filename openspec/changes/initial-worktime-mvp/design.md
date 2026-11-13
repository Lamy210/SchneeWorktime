# Design: SchneeWorktime MVP v0.3 — PR #4 review reinforcement

## Goals / constraints
- macOS 15+ / Swift 6。SwiftUI + AppKit(NSPanel)。`Lamy210/template` は CI/リリース雛形で、アプリ本体はまだない。
- 日次目標=420分、予測休憩=60分、基準終業=18:00（すべて設定可能）。
- 正式なフレックス清算・給与計算を実装しない。就業規則が未確認のため。
- ローカル完結、ネットワーク不要、不要なファイルアクセス/画面監視権限なし。

## Alternatives
| 案 | 運用/セキュリティ | 信頼性 | 性能/費用 | 採否 |
|---|---|---|---|---|
| SchneeGlassに組込み | ファイル管理と勤務記録が結合 | 障害波及 | UI再利用 | 不採用 |
| 新規Swiftアプリ+template | 権限/配布を独立 | native API | 軽量・サーバ費0 | **採用** |
| Tauri/Electron | Web技術再利用 | 通知・常駐ブリッジ必要 | ランタイム増 | 今回不採用 |
共通GlassKitの抽出は複数アプリで契約が成熟するまで保留。

## Architecture
```text
SchneeWorktimeApp (SwiftUI)
 ├ MenuBarExtra + Settings
 ├ DesktopPanelCoordinator (AppKit NSPanel + SwiftUI View)
 └ CompositionRoot
     ├ WorktimeDomain: pure interval rules, projections, reference/surplus
     ├ WorktimeApplication: commands, FSM, correction validation
     ├ WorktimePersistence: versioned local atomic snapshots + backups
     ├ NotificationGateway: UNUserNotificationCenter pending reconciliation
     ├ Clock/Calendar: injectable Instant/time zone/monotonic observation
     └ SystemEvents: wake, clock/time zone changes
```
View/Panel never writes directly to local repository; notification gateway never decides work arithmetic. UI binds to a projection of committed session state.

## Domain and state
- Workday(id UUID, logicalLocalDate, timezoneIDAtStart, profileSnapshot, workIntervals, breakIntervals, state, plannedDeparture, revision, correctionAudit).
- State transitions: notStarted->working; working->onBreak/ended; onBreak->working/ended (clock-out during break requires confirmation and closes the break without creating work); ended->working by explicit same-day resume.
- Work/break intervals are half-open [start,end); at most one open interval; completed intervals have start<end; no overlaps. A workday never automatically splits at midnight.
- UTC-comparable `Instant` for math; local wall time only for display and user inputs. DST nonexistent local times are rejected, duplicated local times explicitly disambiguated.
- At most one unfinished logical workday; use revision-based optimistic updates; invalid edits do not persist or schedule notifications.
- Current workday holds a configuration snapshot; global setting edits apply next day unless explicitly applied to the active workday.

## Deterministic time equations
- `worked(now)=Σ closed work seconds + max(0,now-openWorkStart)` when working; current break/ended contributes no further duration.
- `remaining=max(0,target-worked)`; `surplus=max(0,worked-target)`.
- `recordedBreak=Σ completed actual break intervals`; expected remaining break `max(0,expectedBreak-recordedBreak)` **is an assumption and never actual attendance**.
- When working and target not met: `earliestGoalAt=now+remaining`; `estimatedDepartureAt=earliestGoalAt+assumedBreakRemaining`. No definitive forecast while an open break has unknown end.
- At target crossing, compute earliest historical `actualAchievedAt` by walking validated work intervals; if any contributing span is unverified, show a provisional crossing rather than confirmed achievement.
- Reference end uses logical workday's local date + captured zone. If reference precedes clock-in, mark not applicable; after clock-out fix delta at actual end. Never equate with legal overtime.
- Display duration arithmetic uses seconds; remaining rounds up to minutes, positive earned surplus rounds down; never negative or false completion.
- If actual time moves behind the start of an open interval, surface clock anomaly and suppress unreliable forecast, without silently rewriting persisted Instants.

## Notification strategy
- UserNotification authorization is optional. Notification categories: referenceAt; earliestGoalForecastAt-15m; earliestGoalForecastAt; conditionalSurplusAt[15,30,60]. OS-scheduled notifications only express forecasts. Confirmed achievements require app-side validation of committed intervals.
- Only times strictly in future are scheduled. Use stable logical IDs `workdayId:type:threshold`, comparing ID + trigger Instant + payload version against the **committed** revision. A matching ID alone is insufficient when forecast time moves.
- Reconcile on confirmed changes, app launch, wake, time zone/clock changes and configuration application; remove obsolete pending IDs, add missing future IDs, query OS pending afterward if useful.
- OS removal is asynchronous; delivered requests may not be cancellable. Best-effort pending consistency ≠ exactly-once OS presentation or precise delivery time.
- Achieved/unrecorded-rest alert is informational and prompts break record review when appropriate.
- No notifications scheduled for already ended workdays, and no stale pre-alerts sent retrospectively.

## Storage / failure handling
- Versioned JSON snapshots and correction log under app-owned Application Support; write temporary file -> sync/atomic rename -> validated read/checkpoint; retain bounded known-good backups.
- Canonical state write succeeds before OS notification changes. If persistence fails, keep prior state; if notification fails after persistence, preserve records, show retry.
- Crash recovery scans last valid snapshot, preserves corrupt data for user-reviewed recovery. Never silently initialize empty data on corruption.
- Explicit export via user-selected destination; local deletion requires confirmation. Keep employer names, meeting titles, geolocation and screen activity out of data model.
- Avoid checking real workplace details into public GitHub repository.

## UX / nonfunctional targets
- Lightweight blue/glass panel: worked, remaining, `最短7時間達成`, `休憩込み退勤見込み`, normal reference, source quality flag.
- User can hide panel while menu bar stays interactive. Topmost and all-spaces behavior opt-in. Auto-recover lost display placement.
- Accessibility: VoiceOver, keyboard, high contrast, Reduce Motion, labels separating 実績/予定/未確定.
- Proposed quality gates (not measured SLO): P0 domain/application AC 100%; no lost committed records in forced-write-failure QA; CPU/memory and sleep/wake profiles measured on real Mac before setting quantitative ceiling.
- Major failure modes: macOS sleep during active work, clock/DST changes, notification race, JSON corruption, duplicated session actions, reconfiguration of screens; every case has explicit fallback and test.

## References (verified as documentation, not executed)
- https://openspec.dev/docs/schemas/spec-driven
- https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/removependingnotificationrequests(withidentifiers:)
- https://www.check-roudou.mhlw.go.jp/study/roudousya_tayou_flex.html

## Unverified / postponed
- OpenSpec CLI validation, native macOS build, actual notification QA (not performed in this PR).
- Official employer work settlement, core/flex time ranges and legal overtime computation (not in MVP).

## v0.3: record provenance and trust levels
A local recorded work interval is evidence of the user's **entered schedule**, not independent verification of active work. Use separate quality labels:
- `recorded`: validated interval structure with no unresolved OS anomaly.
- `unverified`: an interval crossing an observed sleep, clock jump, or unexpected long interruption. Display arithmetic and an explicit review prompt but do not assert achievement as confirmed.
- `forecast`: hypothetical future working/rest behavior. Never written to the work history as an actual interval.

Wake detection must not automatically subtract a sleep span or assume that the user was not working. The user explicitly confirms the whole time as work or corrects the interval using regular history editing. Retain the source anomaly, correction and revision in the audit trail.

### FSM corner cases
```text
notStarted --clockIn--> working
working --startBreak--> onBreak
onBreak --endBreak--> working
working --clockOut--> ended
onBreak --clockOut+confirmation--> ended (close break at chosen Instant)
ended --explicit resume--> working (same identified workday)
```
Canceling break-end clock-out preserves the open break. Closed workdays show frozen surplus or shortfall, never a running clock. The application shall prohibit a second open workday while one exists.

### Notification forecast/confirmed split
1. An advance OS request is a **forecast** and its text shall clearly indicate that attendance requires verification. It cannot prove uninterrupted work while the app is suspended.
2. Only app-side re-evaluation of committed verified intervals can label an achievement confirmed; this notice is independent from a potentially previously delivered forecast and the UI must distinguish them.
3. The earliest goal notification assumes no additional break. The projected finish includes remaining expected break. Both labels and timestamps are shown; forecasts remain provisional.
4. Reconciliation compares `(notificationID, fireInstant, payloadRevision)`, removes stale app-owned pending requests and adds replacements. Since OS pending removal is asynchronous and a fire can race a cancellation, the accepted guarantee is eventual convergence, **not** exactly-once delivery.
5. A state commit is completed before notification reconciliation. If schedule write fails afterward, the app retries from the committed revision on startup/wake/config change.
6. Do not post stale missed reminders retrospectively; cancel pending requests when the workday ends, while acknowledging that already-delivered notifications cannot be recalled.
7. Configure a finite set of at-most-once-per-threshold surplus reminders. Default notification text shall not include employer identity or exact individual work history.

Apple platform events to consider: NSWorkspace sleep/wake and NSSystemClockDidChange, plus time zone change. These events trigger a recomputation but never mutate historical intervals without user confirmation.

### Validation properties
- Nonnegative `remaining` and `surplus`, never both strictly positive.
- For ended days, `actualWorked(now1) == actualWorked(now2)` for all later wall times.
- An open break without defined end yields `futureGoalAt=unknown`.
- For working days with viable forecasts, `estimatedDepartureAt >= earliestGoalAt`.
- An unresolved anomaly prevents a claim of confirmed goal achievement.
- Same notification ID with changed fire time shall produce a replacement request.
- Failed persistence cannot produce successful new state or associated notification changes.

### Source documentation
- https://github.com/Fission-AI/OpenSpec/blob/main/docs-lab/reference/schemas/spec-driven/index.md
- https://developer.apple.com/documentation/usernotifications/unusernotificationcenter
- https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification
- https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nssystemclockdidchange
