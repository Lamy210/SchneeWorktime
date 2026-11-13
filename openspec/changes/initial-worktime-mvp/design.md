# Design: SchneeWorktime MVP v0.5 — Daily usability and correctness

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
- State transitions: notStarted->working; working->onBreak/ended; onBreak->working/ended (break-end clock-out requires confirmation and closes the break without creating work); ended->working by explicit resume of the same workday UUID, including after midnight when no later workday exists and no intervals overlap.
- Work/break/non-working-gap intervals are half-open [start,end); at most one active open interval; completed intervals have start<end; categories never overlap. A workday never automatically splits at midnight.
- UTC-comparable `Instant` for math; local wall time only for display and user inputs. DST nonexistent local times are rejected, duplicated local times explicitly disambiguated.
- At most one unfinished logical workday; use revision-based optimistic updates; invalid edits do not persist or schedule notifications.
- Current workday holds a configuration snapshot; global setting edits apply next day unless explicitly applied to the active workday.

## Deterministic time equations
- `worked(now)=Σ closed work seconds + max(0,now-openWorkStart)` when working; current break/ended contributes no further duration.
- `remaining=max(0,target-worked)`; `surplus=max(0,worked-target)`.
- `recordedBreak=Σ completed actual break intervals`; expected remaining break `max(0,expectedBreak-recordedBreak)` **is an assumption and never actual attendance**.
- When working, target is not met and all historical spans are resolved: `earliestGoalAt=now+remaining`; `estimatedDepartureAt=earliestGoalAt+forecastFutureBreakSeconds`, using the explicit active-day rest override if present, otherwise `max(0,expectedBreak-recordedBreak)`. An open break without a known end or unresolved historical time prevents a single exact forecast.
- For workdays with uncertain time, calculate `knownWorkLowerBound` and `recordedWorkUpperBound`; if the lower bound already reaches target, attainment is certain even though the exact crossing time may remain unknown. Only show a single `actualAchievedAt` if invariant under all valid interpretations. Label all results as based on the user's recorded work.
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
- Store each canonical workday's intervals, audit changes and revision in a single validated atomic envelope under app-owned Application Support; write temporary file -> flush as appropriate -> atomic replace -> validation/recovery; retain bounded last-known-good backups. Liveness markers are separate non-attendance metadata and may be lost without making records inconsistent.
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

## v0.4 detailed decisions: interrupted work and uncertainty ranges

### Work-time confidence model
Each explicit workday has one canonical Workday UUID and a captured start-date/timezone. Per-day target defaults to 25,200 seconds. A recorded work interval may be divided logically into `verified` spans and `uncertain` spans identified by sleep, clock anomaly or app-observation gaps. **Verified here means user-entered or reviewed; it does not mean employer-certified attendance.**

- `lowerWorked = sum(verifiedWorkSpans)`.
- `upperWorked = lowerWorked + sum(uncertainSpansThatCouldBeWork)`.
- `remainingRange = [max(0,target-upperWorked), max(0,target-lowerWorked)]`.
- If `upperWorked < target`: 未達確実.
- If `lowerWorked < target <= upperWorked`: 達成可能性あり・要確認.
- If `lowerWorked >= target`: 到達済み確実（記録上）. The exact crossing instant may still be a range; calculate earliest/latest crossings by treating uncertain segments as work/nonwork.
- If a target crossing precedes every uncertain span, keep the original precise actual achievement time.
- On explicit confirmation/correction, update the canonical workday revision, preserve before/after and derive the new goal status. Never treat an OS sleep flag as evidence of unpaid leave.

A future-break override is a forecast-only plan anchored at creation time: `(remainingPlannedRestAtSet, recordedBreakSecondsAtSet, setAtInstant)`. Remaining forecast rest at `now` is `max(0, remainingPlannedRestAtSet - max(0, recordedBreakSecondsNow-recordedBreakSecondsAtSet))`. A completed break after setting the override **consumes** that planned remaining rest; it must not be double-counted. Clearing the override restores the profile-derived future-rest calculation. A goal already achieved is never delayed by future rest.

### Lifecycle, day boundary and state-machine rules
- A graceful app exit does NOT imply clock-out. An open session survives app restarts, subject to an explicit review for any unobserved gap.
- Record a lightweight app-liveness observation independently of canonical attendance revisions while active; missing markers on forced termination means a larger uncertain region rather than invented certainty. Select an event-based or throttled checkpoint frequency after real Mac battery measurements.
- Screen lock without sleep is not automatically a break; OS activity is not actual proof of work.
- Resume after midnight requires explicit selection of an existing logical Workday UUID. If a more recent workday exists, resume is disallowed; history correction remains available.
- Historical **actual** events must not have timestamps later than the reliable current Instant; future clock-out belongs to planned departure only.

### Atomic persistence and privacy
- The last valid committed per-workday envelope includes intervals + correction audit + schemaVersion + revision. Commit/rollback is indivisible, not an independent update of a snapshot followed by audit append.
- A saved state commit is authoritative for notification re-scheduling; OS scheduled notifications are derived state, not the attendance database.
- Updating the same workday from two UI contexts requires serial execution/expected-revision comparison. Failed stale writes cannot silently overwrite.
- User-requested erase removes app-managed history, audit, backups, and locally managed derived attendance artifacts. File exports and Time Machine/system backups remain outside app control and must be disclosed. Do not claim cryptographic security or tamper-proof legal attendance.

### Notification safety contract
- Precise forecast notifications may be scheduled only when target time is a single valid future Instant. When the current uncertainty yields a time range, cancel outdated goal/surplus pending requests and surface review in the UI; reference 18:00 notification remains independently valid if enabled.
- Scheduled notifications **never certify work**. The default UI confirms a recorded goal without issuing a duplicate OS alert after a recent goal forecast; a separate confirmed OS notification is opt-in.
- Compare notification ID, trigger Instant and content-version against pending OS requests; cancel/recreate stale requests and re-check convergence. Asynchronous cancellation and delivered-notification races remain OS-level limitations.
- Sleep, restart, clock/timezone changes, break state changes, correction, resume, and profile application all trigger a reconciliation from committed workday state.

### UI state table
| Workday view | Primary time | Secondary information | Action |
|---|---|---|---|
| Not started | 未開始 | 参考18:00 if enabled | 出社時刻を入力 |
| Working / determined | 休憩込み退勤見込み | 最短達成、残り実働、基準差 | 休憩・退勤 |
| Working / uncertain | 要確認 + 残り時間の範囲 | 記録上の達成可能性 | 確認・訂正 |
| On break / unknown end | 時刻未確定 | 残り実働 | 休憩終了・退勤 |
| Ended / shortfall | 不足の固定時間 | 退勤時刻、記録実働 | 修正・再開 |
| Ended / achieved | 達成済み | 達成時刻（確定または範囲） | 履歴確認 |

### Revised quality gates
- All P0 arithmetic/transition/reconciliation cases pass deterministic FakeClock/FakeStore/FakeNotification tests; check numeric boundary values and nonoverlap properties.
- Forced-write-failure tests show no mixed audit/revision states, even after application restart.
- macOS wake/sleep, permission denied, no-network, external monitor removal and accessibility are verified manually in addition to pure tests.
- CPU, memory, battery and UI refresh are measured on a real Mac; thresholds are chosen after baseline measurement rather than asserted without evidence.

### v0.4.1 uncertainty classification: work / rest / non-work gap
- An unresolved interval has three explicit outcomes: **勤務継続** (adds to work), **実際の休憩** (adds only to recorded unpaid break), or **非勤務ギャップ** (adds to neither work nor rest).
- A non-work gap must split work intervals and be classified in the canonical workday/audit. It does not satisfy any expected unpaid rest; do not label it a break for convenience.
- Example: 11:30開始、16:30〜17:30未確認、17:30時点の実働は5h。分類を非勤務ギャップにすると最短19:30・残り予定休憩60m込み退勤20:30。分類を休憩にすると最短19:30・休憩実績60m・退勤19:30。
- UI must offer the three choices with a preview and explicit save; all corrections use the same revision, atomic envelope, and future notification reconciliation.
- App shutdown, lock, sleep or wake by itself never determines which of these classifications is correct.

## v0.5 product usability decisions

### The first-screen answer
- Compact Glass shows **退勤見込み** as the dominant value, then `残り実働`, `実働済み/7時間`, `最短7時間` and the optional `参考18:00との差`.
- One-tap state-appropriate commands from menu bar and floating surface: clock-in, start/end break, clock-out, simulate departure. Invalid actions must not be executable.
- When entering the day late, allow explicit backdated actual clock-in with full interval validation; do not force users to clock in at the current time. Future actual times are rejected.
- Expanded Glass exposes a timeline of verified work/break/nonwork segments, assumption labels, and a what-if editor. Compact/expanded modes must remain keyboard and VoiceOver accessible.

### What-if simulation contract
- `previewDeparture(candidateInstant, optionalForecastRest)` is a **pure query**, not a command: it must not update the canonical workday, planned departure, notification generation, revision, or audit.
- Candidate is in the future relative to the currently displayed clock time and not earlier than workday start. A 'leave now' preview is valid with candidate=now.
- Result is a prediction of actual net work at the candidate Instant given the remaining planned break budget. A preview with previously unresolved work shows lower/upper bounds and assumption labels, not a single exact surplus.
- A separate **Save as planned departure** confirmation may update `plannedDepartureAt` and only then trigger notification reconciliation (if dependent). Closing/dismissing the preview must change no persistent state.
- Example (Asia/Tokyo): 11:30 clock-in, 12:00–13:00 break, at 18:10: leave 19:00 -> projected net 390 minutes, 30 minutes short; leave 20:00 -> 450 minutes, 30 minutes above the 420-minute *personal target*. No legal overtime statement.

### Quick control / UI state
| State | Immediate actions | Disabled actions |
|---|---|---|
| notStarted | 今から出社, 始業時刻を入力 | 退勤, 休憩終了 |
| working | 休憩開始, 退勤, 退勤予定を試算 | 重複出社 |
| onBreak | 休憩終了, 退勤（確認付き） | 重複休憩開始 |
| ended | 履歴, 訂正, 明示再開 | 休憩開始 |
| uncertain | 区間確認, 訂正, 予測を見る | 未確認の実績を確定と断定する動作 |

### Notification lead controls
- Default is 15 minutes before the earliest calculated goal; offer optional 30- and 5-minute leads as separately enabled choices. Suppress duplicates and skip elapsed lead times without retroactive delivery.
- Ask for authorization **in context** when the user enables reminders, not automatically on first launch. Continue all other features on denied permissions.
- Only one precise goal timestamp may drive reminders; uncertain time spans, an open break with unknown end, or invalid clock causes suppression and the UI explains why.
- OS scheduling may deliver a previously booked forecast despite changed real-world work. Notification content must always say `見込み`, not confirmed attainment.

### Scope boundary
- `docs/SchneeWorktime/FEATURE_DISCOVERY.md` is a backlog of candidate delight features, not 32 additional mandatory release requirements.
- `docs/SchneeWorktime/UX_JOURNEYS.md` is the scenario-level usability contract.
- `docs/SchneeWorktime/RELEASE_SCOPE.md` locks M0/M1/M2 boundaries; weekly totals, calendars, widgets, Shortcuts and idle automation are not silently included in M0.

### Platform constraints
- macOS `MenuBarExtra` provides persistent access; when an application consists *only* of a menu bar extra, removing that extra may terminate the app. Test alternate Glass/settings recovery and avoid unintentional data loss.
- WidgetKit supports Mac desktop widgets, but it is not a drop-in continuously refreshing countdown surface. Keep minute-level live display in the app surface; consider widgets separately.
- App Intents can provide actions for the Mac Shortcuts application. Apple HIG states **App Shortcuts themselves are not supported in macOS**; do not conflate the two products.
- EventKit calendar reading requires permission. Do not add calendar access to the initial local-first release.

### Sources
- https://developer.apple.com/documentation/swiftui/menubarextra
- https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy
- https://developer.apple.com/documentation/appintents
- https://developer.apple.com/design/human-interface-guidelines/app-shortcuts
- https://developer.apple.com/documentation/UserNotifications/asking-permission-to-use-notifications
- https://developer.apple.com/documentation/eventkit/accessing-the-event-store
