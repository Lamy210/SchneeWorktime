# Design: SchneeWorktime MVP v0.7 — Consistent contracts and tested domain foundation

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
     ├ WorktimePersistence: transactional local store + versioned backups
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
- `recordedBreak=Σ actual break intervals clipped to the observation Instant`; expected remaining break `max(0,expectedBreak-recordedBreak)` **is an assumption and never actual attendance**.
- When working, target is not met and all historical spans are resolved: `earliestGoalAt=now+remaining`; `estimatedDepartureAt=earliestGoalAt+forecastFutureBreakSeconds`, using the explicit active-day rest override if present, otherwise `max(0,expectedBreak-recordedBreak)`. An open break without a hypothetical return or unresolved historical time prevents a single exact forecast.
- For workdays with uncertain time, calculate `knownWorkLowerBound` and `recordedWorkUpperBound`; if the lower bound already reaches target, attainment is certain even though the exact crossing time may remain unknown. Only show a single `actualAchievedAt` if invariant under all valid interpretations. Label all results as based on the user's recorded work.
- Reference end uses logical workday's local date + captured zone. If reference precedes clock-in, mark not applicable; after clock-out fix delta at actual end. Never equate with legal overtime.
- Display duration arithmetic uses seconds; remaining rounds up to minutes, positive earned surplus rounds down; never negative or false completion.
- If actual time moves behind the start of an open interval, surface clock anomaly and suppress unreliable forecast, without silently rewriting persisted Instants.

## Notification strategy
- UserNotification authorization is optional. Categories: departurePreparationAt (default 15 minutes before feasible break-adjusted departure or saved plan), optional earliestGoalForecastAt (separate opt-in), referenceAt, conditionalSurplusAt[15,30,60]. OS-scheduled notifications express forecasts only. Confirmed achievements require app-side validation.
- Only times strictly in future are scheduled. Use stable logical IDs `workdayId:type:threshold`, comparing ID + trigger Instant + payload version against the **committed** revision. A matching ID alone is insufficient when forecast time moves.
- Reconcile on confirmed changes, app launch, wake, time zone/clock changes and configuration application; remove obsolete pending IDs, add missing future IDs, query OS pending afterward if useful.
- OS removal is asynchronous; delivered requests may not be cancellable. Best-effort pending consistency ≠ exactly-once OS presentation or precise delivery time.
- Achieved/unrecorded-rest alert is informational and prompts break record review when appropriate.
- No notifications scheduled for already ended workdays, and no stale pre-alerts sent retrospectively.

## Storage / failure handling
- Store canonical intervals, active ID, catalog, audit and revisions together in a single app-wide transaction under app-owned Application Support. Retain validated last-known-good backups subject to the erase epoch. Liveness markers are separate non-attendance metadata; losing them cannot assert working time.
- Canonical state write succeeds before OS notification changes. If persistence fails, keep prior state; if notification fails after persistence, preserve records, show retry.
- Crash recovery scans last valid snapshot, preserves corrupt data for user-reviewed recovery. Never silently initialize empty data on corruption.
- Explicit export via user-selected destination; local deletion requires confirmation. Keep employer names, meeting titles, geolocation and screen activity out of data model.
- Avoid checking real workplace details into public GitHub repository.

## UX / nonfunctional targets
- Lightweight blue/glass panel: worked, remaining, `最短7時間達成`, `休憩込み退勤見込み`, normal reference, source quality flag.
- User can hide panel while menu bar stays interactive. Topmost and all-spaces behavior opt-in. Auto-recover lost display placement.
- Accessibility: VoiceOver, keyboard, high contrast, Reduce Motion, labels separating 実績/予定/未確定.
- Proposed quality gates (not measured SLO): P0 domain/application AC 100%; no lost committed records in forced-write-failure QA; CPU/memory and sleep/wake profiles measured on real Mac before setting quantitative ceiling.
- Major failure modes: macOS sleep during active work, clock/DST changes, notification race, store/database corruption, duplicated session actions, reconfiguration of screens; every case has explicit fallback and test.

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
- `unverified`: an interval crossing an observed sleep, clock jump, or unexpected long interruption. Display arithmetic and a review prompt. The span cannot be counted as verified work; attainment may nevertheless be certain if other verified work meets the target.
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
Canceling break-end clock-out preserves the open break. Closed workdays show frozen work bounds and attainment status, never a running clock; an explicitly committed history correction may recompute them. The application shall prohibit a second open workday while one exists.

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
- An unresolved anomaly prevents confirmed attainment only when the verified lower bound is below target; it prevents exact crossing time only when it can change that time.
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

A future-break override is a forecast-only plan with `(restRemainingSecondsAtSet, setAtInstant, workdayRevisionAtSet)`. Its consumption is the sum of **actual break intervals intersecting `[setAtInstant,now]`**, recomputed after any history correction. `remaining = max(0, restRemainingSecondsAtSet - consumedBreakSeconds)`. Changing a break that occurred strictly before the plan must NOT consume future rest. Clearing the override restores the profile-derived calculation. An achieved goal is never delayed by future rest.

### Lifecycle, day boundary and state-machine rules
- A graceful app exit does NOT imply clock-out. An open session survives app restarts, subject to an explicit review for any unobserved gap.
- Record a lightweight app-liveness observation independently of canonical attendance revisions while active; missing markers on forced termination means a larger uncertain region rather than invented certainty. Select an event-based or throttled checkpoint frequency after real Mac battery measurements.
- Screen lock without sleep is not automatically a break; OS activity is not actual proof of work.
- Resume after midnight requires explicit selection of an existing logical Workday UUID. If a more recent workday exists, resume is disallowed; history correction remains available.
- Historical **actual** events must not have timestamps later than the reliable current Instant; future clock-out belongs to planned departure only.

### Atomic persistence and privacy
- The committed application-wide catalog includes all workday envelopes (intervals, audit, schemaVersion, per-day revision), active ID and global generation. Commit/rollback is indivisible, not an independent update of a snapshot followed by audit append.
- A saved state commit is authoritative for notification re-scheduling; OS scheduled notifications are derived state, not the attendance database.
- All write commands, including across processes, require store-wide serialization and expected global revision/epoch comparison. Failed stale writes cannot silently overwrite.
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
| Ended / possible | 達成の可能性あり・要確認 | 固定実働範囲、未来予測なし | 履歴訂正 |

### Revised quality gates
- All P0 arithmetic/transition/reconciliation cases pass deterministic FakeClock/FakeStore/FakeNotification tests; check numeric boundary values and nonoverlap properties.
- Forced-write-failure tests show no mixed audit/revision states, even after application restart.
- macOS wake/sleep, permission denied, no-network, external monitor removal and accessibility are verified manually in addition to pure tests.
- CPU, memory, battery and UI refresh are measured on a real Mac; thresholds are chosen after baseline measurement rather than asserted without evidence.

### v0.4.1 uncertainty classification: work / rest / non-work gap
- An unresolved interval has three explicit outcomes: **勤務継続** (adds to work), **実際の休憩** (adds only to recorded unpaid break), or **非勤務ギャップ** (adds to neither work nor rest).
- A non-work gap must split work intervals and be classified in the canonical workday/audit. It does not satisfy any expected unpaid rest; do not label it a break for convenience.
- Example: 11:30開始、16:30〜17:30未確認、17:30時点の実働は5h。分類を非勤務ギャップにすると最短19:30・残り予定休憩60m込み退勤20:30。分類を休憩にすると最短19:30・休憩実績60m・退勤19:30。
- UI must offer the three choices with a preview and explicit save; all corrections use the same revision, app-wide atomic transaction, and future notification reconciliation.
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
- A separate **Save as planned departure** confirmation (with explicit warning acknowledgement for infeasible/unknown projections) may update `plannedDepartureAt` and only then trigger notification reconciliation (if dependent). Closing/dismissing the preview must change no persistent state.
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
- Default notification lead is 15 minutes before the **break-adjusted departure estimate** (or explicitly saved departure plan) when it is feasible. Offer optional 30/5-minute leads. The earliest no-more-break 7h milestone is a distinct opt-in notification; never silently substitute it for departure preparation.
- Ask for authorization **in context** when the user enables reminders, not automatically on first launch. Continue all other features on denied permissions.
- Each notification category must have its own eligible single trigger Instant. Suppress each precise forecast whose inputs are infeasible, ambiguous or missing while preserving other independently eligible reminders. If the system clock is unreliable, suppress all time-based reminders including reference until it is trustworthy.
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

## v0.6 — Feasibility first; forecast vs. schedule

### Correctness finding corrected
The prior v0.5 `leave at 19:00` scenario had no explicit current time and could appear mathematically valid even if it was already 18:10 and a full 60-minute break was still required in the remaining 50 minutes. **Future breaks must fit in future elapsed time**; forecasts shall not travel backward or subtract 60 minutes from already accumulated actual work.

### Forecast eligibility
- `availableFutureSeconds = candidateDepartureAt - observedAt`; require `>=0`. `0` is an allowed leave-now query.
- A conditional forecast assuming full future rest is eligible only if `0 <= remainingPlannedRestSeconds <= availableFutureSeconds`; otherwise mark `infeasible` with the mismatched durations and offer an explicit change to rest/departure time. Do not auto-clamp.
- An unknown open-break end or unresolved historical attendance yields `unknown` or a **range**, not one precise predicted departure. If the user provides a hypothetical return time, label it forecast-only; do not record the break end as an actual event.
- Check feasibility even when there is enough remaining work time: input constraints can conflict independently from whether 420 minutes have been recorded.
- `previewDeparture` is pure: neither workday intervals, plannedDepartureAt, notifications, revision nor audit changes. The preview carries `(workdayRevision, observedAt)` and expires on workday mutation or candidate time passing. Explicit Save As Plan must revalidate against latest state and show warnings, especially if the planned break is infeasible.

### Worked examples (Asia/Tokyo)
| Start / now / candidate | Recorded break | Future rest assumption | Outcome |
|---|---:|---:|---|
| 11:30 / 12:00 / 19:00 | 0 | 60m | feasible: 30m worked before now + 360m future work = 390m, 30m short |
| 11:30 / 18:10 / 19:00 | 0 | 60m | **infeasible**: only 50m available for 60m of rest |
| 11:30 / 18:10 / 19:00 | 0 | 30m explicit override | feasible: 400m worked before now + 20m future work = 420m |
| 11:30 / 18:10 / now | 0 | 60m | leave-now preview uses worked 400m; 20m short; does not subtract rest |
| 11:30 / 18:10 / 19:00 | 60m recorded 12:00–13:00 | 0 | feasible: 340m + 50m = 390m, 30m short |

### Distinguish reminders
- **Departure preparation (default)**: break-adjusted departure 19:30 → lead 15m at **19:15**.
- **Earliest goal (opt-in)**: uninterrupted-goal 18:30 → lead 15m at **18:15**.
- **Reference (optional)**: independent reference 18:00, unrelated to actual work attainment or official overtime.
- **Explicit planned departure**: if saved, it is distinct from the computed estimate; the default preparation reminder follows the saved intent, showing any projected shortfall. An impossible forecast is never presented as feasible simply because the user saved a plan. Saving infeasible or unknown intent requires warning acknowledgement; suppress its preparation reminder rather than silently reverting to a different time.
- If actual target attainment is validated earlier than the forecast, cancel future derived goal-based preparation reminders best effort. Retain eligible explicit desired-departure reminders; preserve separate break-record advisory.

### Break duration advisories
The default break assumption is 60 minutes, but it is not always identical to a legal minimum. According to the Ministry of Health, Labour and Welfare, for work exceeding 6 hours the legal minimum is 45 minutes; for work exceeding 8 hours it is 60 minutes (subject to actual employment conditions and exceptions). Present this as **check your recorded break and rules** rather than inferring a statutory violation from a personal log. Never fabricate breaks, auto-clock out or block saving an otherwise valid work record.

### Supporting documents
- docs/SchneeWorktime/FORECAST_SEMANTICS.md
- docs/SchneeWorktime/NOTIFICATION_POLICY.md
- docs/SchneeWorktime/ACCEPTANCE_MATRIX.md (AC-105 to AC-121)
- https://www.mhlw.go.jp/stf/seisakunitsuite/bunya/koyou_roudou/roudoukijun/roudouzikan/index.html

## v0.7 consolidated contracts (supersedes conflicting earlier examples)

- Attainment and crossing are orthogonal: lower >= target implies reached even if crossing is a range. If upper >= target but lower < target, status is possible and no guaranteed crossing instant exists. Never call the record employer-certified. Ended records freeze these values at clock-out, not an invented single value.
- `plannedDepartureAt` represents explicit user intent, not calculated `estimatedDepartureAt`. Future infeasible/unknown intent can be saved after acknowledging a warning. A passed plan remains historical intent and is not clock-out. Never create a future plan at or before now.
- A saved plan takes preparation priority only when presently feasible with precise projected work. Otherwise show the conflict and suppress that reminder (do not fall back silently). Reference and earliest-goal categories are evaluated independently. An eligible saved plan can remain after target attainment; derived target-based preparation is retired.
- Break elapsed to now consumes rest. For active break return assumption R, future obligatory break = R-now. With remaining budget B after elapsed rest, future rest=max(B,R-now) rather than B+(R-now). R must be in [now,candidate]. A leave-now preview ignores future rest; ended records allow no future preview until explicit resume. Never create a real event from a preview. Work bounds use a fixed stated rest assumption based on recorded rest only, not speculative rest classifications.
- Reference configuration includes explicit dayOffset 0 or 1, default 0, in the captured timezone. Resolve DST ambiguity explicitly, reject nonexistent local times.
- Persistence: choose **one application-wide transactional store** containing catalog/active ID, records/audit and store generation. A single database transaction (SQLite is the proposed adapter) enforces cross-workday nonoverlap and max one active, serialized writer and stale-generation rejection. Backup restore validates every invariant and rejects ambiguous active days. An erase commits an epoch boundary before deleting old backups; incomplete erase is reported and old generations are fenced off from automatic restoration. The adapter, crash-safety tests and backup design remain unimplemented.
- The dependency-free SwiftPM module `Packages/WorktimeDomain` validates raw recorded intervals, unions overlapping observation gaps, clips open intervals to the observation time, and computes work bounds/crossing, anchored rest budget and conditional departure feasibility. It also contains a value-only WorkdayCatalog for ordinary clock-in/break/clock-out/resume commands and optimistic revision checks. Historical correction, audit, persisted observation metadata, timezone resolution, persistence and notification delivery remain unimplemented. Test via `swift test --package-path Packages/WorktimeDomain`. Do not infer app completion from these unit tests.

### Observation and revision consistency
Lifecycle observation gaps are separate, versioned local metadata, not evidence of attendance and not user edits. A derived preview is invalidated when either the committed workday revision or the observation generation changes; revalidate at the current Instant before saving. Notification reconciliations must be serialized and generation-fenced against both sources, including after an asynchronous OS operation returns. A backward clock or invalid gap endpoint yields unavailable arithmetic rather than invented valid Instants. No automatic historical edit or legal attendance claim is made. The Application/OS adapters that enforce these rules are not yet implemented.

## v0.8 — Ordinary workday command boundary
- Clock-in creates a unique UUID with a fixed target/rest profile; the app-wide revision increases once per accepted command. A day's revision identifies the most recent mutation affecting it. A new day must start at or after the latest closed end and only when no active day exists. Historical insertion is reserved for a correction command.
- A close operation must occur strictly after its open interval's start. Same-second close/transition returns a typed error without mutation; an open interval with zero elapsed seconds remains valid. Resume may occur exactly at a closed end; the resumed gap never counts as work or rest.
- State and intervals are returned together. Clock-out during a break requires explicit confirmation, then closes only the break. Resume is restricted to the latest ended day and retains its UUID/profile.
- The new WorkdayCatalog is an **in-memory value aggregate**, not a database. Its expected-revision check is not a durable concurrency guarantee: the store must serialize writers, re-read the catalog under a transaction, check epoch/revision, and commit the same resulting state/audit atomically. The caller supplies trusted absolute-second Instants and observation gaps associated with the queried records; clock trust, local date/timezone capture, history editing, saved rest/departure plans and observation-generation management remain adapter/application work. Ended snapshots validate observations at trusted now, then clip them to the final actual end as the evaluation Instant. Valid observations after actual end do not invalidate or inflate closed work.

### Catalog-integrated review (v0.8)
- Catalog owns per-day observation ranges, an observation generation and review audit. Observation writes are separate from attendance revisions. Only the active day accepts new observation events; delayed or replayed events require the current revision/generation and must subtract previously explicitly resolved ranges. Duplicate observation coverage is a no-op.
- The application uses catalog.snapshot(dayID:now:) for authoritative derived values, not the lower-level Workday.snapshot with omitted uncertainty. Review preview is pure; commit recomputes from canonical intervals/observations, checks both generations and before/after evidence, then updates the reviewed day, observations, audit and catalog counters together in the value aggregate. Review of an ended day does not modify a newer active day. A successful review records the actual commit Instant.
- This is an in-memory contract only. The SQLite adapter must commit the same aggregate atomically, check a durable store epoch in addition to both counters, and retain review evidence across restarts. No claim of persistent audit, multi-process serialization, durable deletion, or automatic clock trust is made.

### SQLite snapshot storage foundation
- Add WorktimeStore with a platform SQLite3 system-library target, separate from WorktimeDomain. The first implementation stores one opaque payload in a STRICT table (SQLite >=3.37 required), schema version 1, store epoch UUID and nonnegative store revision. The store revision counts durable commits, independent of catalog revision and observation generation. Initial/reset payload is NULL at revision zero; saved payload is a nonempty blob.
- Use BEGIN IMMEDIATE, re-read and compare the entire expected store version in the transaction, bind payload with prepared statements and commit once; synchronous FULL, busy timeout 5000ms. Reject stale writes and invalid sizes. Initial nonempty blob limit is 16 MiB, a provisional resource bound requiring capacity measurements and migration planning.
- Explicit createIfMissing is permitted only on trusted first installation, not on ordinary startup or restore. Existing unsupported/empty databases and missing databases on ordinary reopen fail closed. The caller owns the app-private directory and must select whether creation is authorized; the adapter does not establish filesystem ownership or confidentiality.
- Logical reset changes epoch and clears the live row; it is NOT physical deletion, secure erase or a backup fence. A copied older database can still contain erased data. Independent durable erase fencing, backup recovery, filesystem protections, concurrent-process and injected-crash tests are still required.
- This transport persists opaque bytes, not yet a validated WorkdayCatalog. The next layer must encode/decode a versioned canonical catalog including all intervals, observation generations, review audit and active identity; reject malformed or inconsistent decoded data; do not publish mutations until store commit succeeds. No end-to-end work-record persistence claim until those tests pass.

### Validated journal coordinator
- Implement schema v1 as an ordered JSON operation journal inside the SQLite snapshot. Replay through WorkdayCatalog instead of decoding writable canonical state directly; the journal includes explicit actual Instants, supplied observation Instants, selected review classification and commit Instant. It reconstructs UUIDs, revisions, observations and audit deterministically. The current replay parser rejects unsupported schema, malformed JSON, invalid domain transitions, duplicate no-op events, count mismatch and events observed after trusted current time. It does not authenticate a journal against malicious replacement.
- A single accepted non-no-op operation increments store revision once; its domain revision/generation changes according to the domain operation. Repository reloads and compares the expected store version before mutation; SQLite CAS rechecks under BEGIN IMMEDIATE before persisting the candidate. The changed catalog is returned only after successful save. Review proposals carry the original store epoch/revision in addition to their domain version, preventing reuse after reset.
- Provisional limit: 10000 events and existing 16 MiB payload cap. Full replay/rewrite cost grows with history; benchmark before production, and design compatible checkpointing/migration before capacity is exhausted. No automatic compaction or destructive recovery. Old backup restoration still needs an independent erase fence. Clock rollback currently returns an error; a trustworthy recovery path and UI are pending.

### Reference resolution and read-only forecast foundation
- ReferenceContext captures a supplied start Instant and timezone ID, uses Gregorian civil dates and strict local matching with explicit dayOffset zero or one. It detects skipped days, nonexistent wall times and ambiguous repeated wall times; ambiguous selections specify earlier/later. The supported input/output Instant range is 1900–9999 UTC (provisional safety bound). Persisting the captured context, profile and resolved Instant across app relaunch or timezone database changes remains application work.
- DailyForecast derives remaining-work and surplus ranges from validated worked bounds and a positive target. It returns projected, reached, uncertain, onBreak or ended. The projected case exposes the earliest goal timestamp plus separate departure estimate including outstanding assumed rest, with checked additions. It does not choose a planned departure, schedule notifications or mutate attendance. The caller must supply a trusted current Instant and canonical snapshot (including frozen ended durations); stale preview invalidation and app clock trust remain separate.
- The two new pure calculation components have 11 passing tests in an isolated Linux SwiftPM package using the unchanged Worktime.swift blob. Integrated CI/macOS DST behavior and persistence wiring remain to be verified.

### Prototype application adapter
WorktimeController is a single-owner value wrapper over CatalogRepository and a read-only WorktimeGlance. Apply is fenced by a store epoch/revision; foreground commands observe the clock before writing. The polling ClockObservation uses an initial wall/uptime anchor and rejects decreases or divergence above two seconds. A gap greater than fifteen seconds is conservatively recorded for the intersection with the current open work interval. Startup marks the entire open work interval as unverified (no persisted heartbeat yet); domain review suppresses previously resolved ranges. These thresholds are provisional, not proof of attendance; native sleep/lock hooks, durable heartbeat, full recovery UI and multi-instance enforcement are release blockers. On error the desktop discards its controller and requires explicit reload. The prototype refreshes on a one-second main-run-loop timer; power and main-thread replay cost require measurement.

The SwiftPM executable provides a macOS MenuBarExtra and explicitly initialized local SQLite DB. It offers normal start/break/end/resume commands, confirmation for exit during break, work bounds and typed daily forecasts. No automatic attendance or time-zone reference persistence is implemented here. It does not fulfill the full desktop requirements (Glass surface, historical/partial review UI, desired-departure preview/save, accessibility/hidden-render behavior), notifications or distributable .app. The prototype is not a release candidate until remaining P0 gates are satisfied.

### Initial review interaction
WorktimeGlance lists only intersections of unresolved observation ranges and actual work intervals within the latest workday, preserving each interval's boundary. The review adapter observes the clock before preview or commit; an observation may independently persist a new uncertainty range, but preview never persists a review or mutates the canonical workday. A value-copy projection at the observation Instant shows before/after work and forecasts. Only explicit confirmation commits the stored review through the repository's epoch/revision CAS and domain versions. The UI invalidates proposals on observed version changes, and clock/storage failures stop writes. It displays exact seconds for the review range and work bounds. The initial menu handles the first complete unresolved segment of the latest day; mixed segments must not be accepted as a single classification. Arbitrary subranges, prior-day navigation, correction of already reviewed classifications, and native UI QA remain release blockers.
