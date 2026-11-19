# Workday Contract — SchneeWorktime v0.7

## Purpose
本書はOpenSpecの補足設計資料であり、実装コードではない。MVPの事実・予測・不明を混同しないためのデータ契約を明文化する。

## Canonical workday envelope
- `workdayId: UUID`: 明示的に作成した勤務記録の一意ID。日跨ぎで変更しない。
- `logicalStartDate`、`capturedTimeZoneID`: 勤務開始時に確定した表示/基準時刻の文脈。
- `profileSnapshot`: `dailyTargetSeconds=25200`、`expectedBreakSeconds=3600`、`referenceEndLocalTime=18:00?`、`referenceDayOffset=0|1`。
- `state`: `notStarted | working | onBreak | ended`（各workdayの保存時はnotStarted無しでも可）。
- `workIntervals`、`breakIntervals`、`nonWorkGapIntervals`: half-open absolute intervals `[startInstant,endInstant)`。3つの種別は互いに重ならず、最後のアクティブ区間のみend=null可。
- `uncertainSpans`: 元の勤務区間に含まれ、勤務か非勤務か未確認のintervalとその観測理由。
- `futureRestPlan?`: `restRemainingSecondsAtSet`、`setAtInstant`、`workdayRevisionAtSet`。入力以後に**実際の休憩区間と重なった時間**だけ予定休憩を消費する。入力以前の休憩の訂正で消費量を誤更新しない。
- `plannedDepartureAt?`: 本人が明示保存した希望退勤。未来かつ警告確認済みなら試算不整合でも保存可能。実際のclock-outや自動算定見込みとは区別。
- `correctionAudit`: revision、before/after、訂正時刻、訂正の由来、任意のコメント。
- `schemaVersion`、`revision`: 単一の原子的保存単位に含める。

実際のclock-out、休憩、勤務のtimestampは未来を禁止する。未来時刻は計画専用。保存前にwork/break/uncertainの区間境界・重複・状態遷移を全件検証する。

## Derived values (never stored as source of truth)
- `knownWorkSeconds` = すでに確認された勤務区間の長さ。
- `possibleWorkSeconds` = 既知勤務 + 未確認区間（可能性として勤務）の長さ。
- `remainingMinSeconds = max(0, target - possibleWorkSeconds)`
- `remainingMaxSeconds = max(0, target - knownWorkSeconds)`
- `referenceDeltaSeconds` = 対象勤務日/タイムゾーンに固定された基準終業Instantとの差分。法定残業ではない。
- `earliestGoalAt` と `estimatedDepartureAt` は単一の予測時刻が導出できる場合のみ提示。
- `actualAchievedAt` はすべての有効な未確認区間の解釈で同じ時刻になる場合のみ確定。
- 達成の確実性は下限>=targetで成立し、達成**時刻**の確実性とは別。

## State transitions
| 現在の状態 | 操作 | 次の状態 | 原則 |
|---|---|---|---|
| 未開始 | 出社 | working | 開いた勤務区間を1つ作成 |
| working | 休憩開始 | onBreak | 勤務を閉じ、休憩開始 |
| onBreak | 休憩終了 | working | 休憩を閉じ、勤務再開 |
| working | 退勤 | ended | 勤務を閉じ、全予報通知を解除 |
| onBreak | 退勤＋確認 | ended | 休憩を閉じて退勤。勤務区間を増やさない |
| ended | 同一UUIDの明示的再開 | working | 後続勤務日が無い場合のみ。退勤後のgapは実働外 |
| any | 履歴訂正 | unchanged/appropriate | revisionと時刻/区間が妥当な場合だけcommit |

## Work examples (Asia/Tokyo)
### 11:30出社 / 12:00〜13:00休憩 / 現在18:10
- 実働340分、残り80分、最短到達19:30、退勤見込み19:30、基準18:00から10分超過。
- これは正式な残業10分を意味しない。

### 11:30出社 / 休憩未取得 / 11:31現在
- 実働1分、残り419分。
- 最短到達18:30、休憩予定60分込み退勤見込み19:30。
- 予定休憩を明示的に30分へ変更したら退勤見込み19:00。実際の休憩を0分と偽記録しない。

### 11:30出社 / 16:30〜17:30未確認 / 現在19:30
- 確認済み記録の実働下限420分、未確認を全勤務とした上限480分。
- 7時間に達していること自体は記録上確実。到達時刻は18:30〜19:30。
- 後で未確認を休憩にしたら到達19:30。勤務にしたら到達18:30。

## Persistence and notifications
- Workday本体と監査logは1つのcommitとしてwrite/replaceする。失敗時は前revisionを保護。
- アプリ観測マーカーは勤務とは別のメタデータ。メタデータの紛失は勤怠記録の欠損とみなさない。
- OS通知は保存された実績から導くキャッシュ的な予約。復旧時は最新revisionを再計算し、過去の通知を遡及送信しない。
- 未確認により目標時刻が範囲となる場合は、精密な目標・超過通知の予約を抑止する。
- 全履歴削除時はapp-owned history/audit/backupsを対象にする。外部へexportしたファイルはアプリから削除しない。

## Open assumptions
- このアプリは勤怠システムの正本ではなく、ユーザー入力を基にした参考用ツール。
- 会社の清算期間・法定残業・有給休憩の扱いは確認できていないためMVP外。

## Three-way review and forecast rest consumption
- 未確認区間の訂正は、**勤務継続 / 実際の無給休憩 / 非勤務ギャップ**の3種類を提供する。
- 休憩だけが累積休憩実績を増やす。非勤務ギャップは勤務・休憩のどちらにも入らず、既定の休憩60分の消化とみなさない。
- 11:30開始、16:30〜17:30を非勤務ギャップとし17:30現在の場合：実働5時間、最短19:30、標準休憩60分込み退勤20:30。
- 同区間を休憩とする場合：実働5時間、休憩実績60分、退勤見込み19:30。
- 将来の休憩予定残り30分を設定し、その後10分の休憩を記録したら将来の残りは20分。40分の休憩を記録したら将来の残りは0分（マイナスにしない）。
- 11:30開始、休憩予定残り30分設定後に実績40分を取得した場合、最短達成19:10、退勤見込み19:10。追加で予定30分を加算しない。

## v0.6 — departure forecast contract
- `previewResult` is read-only `{workdayRevision,observedAtInstant,candidateDepartureInstant,feasibility,knownWorkRange,plannedRestAssumption,shortfallOrSurplus}`. It is never canonical history.
- Feasibility values: `feasible | infeasible | unknown`. `candidate<now` is invalid for a **future** forecast; `candidate==now` is valid and ignores future rest.
- Let `futureWindowSeconds=candidate-now`. If planned future break exceeds the window, `feasibility=infeasible`, not a misleading numeric result.
- If the break end is unknown or historical work has unresolved ranges, a precise forecast may be `unknown`; show the reason and review action.
- `earliestGoalAt`, `estimatedDepartureAt`, `plannedDepartureAt`, `referenceEndAt` are distinct Instants and must never be treated as interchangeable.
- Default departure preparation reminders use an eligible explicit saved plan, or the computed estimate only when no plan exists. Ineligible saved plan suppresses its reminder; earliest-goal is independent and opt-in.
- Each preview is invalidated on workday revision/observed time expiry; a Save As Plan request re-evaluates the constraints.
- `futureRestPlan` consumption: sum of actual break intervals intersected with `[setAtInstant,now]`. Edits before `setAtInstant` do not count toward future rest. Preserve audit and validation on every correction.
- The default 60-minute anticipated break is a personal planning assumption. A brief break-advisory may draw attention to the recorded duration without claiming formal legal compliance.

### Calculation examples
| Situation | Candidate | Outcome |
|---|---|---|
| 11:30出社、12:00現在、実績休憩0、今後休憩60分 | 19:00 | 未来7時間に休憩が収まる。実働6時間30分見込み、30分不足 |
| 11:30出社、18:10現在、実績休憩0、今後休憩60分 | 19:00 | 未来50分に休憩60分を置けず**実現不能** |
| 上記で今後休憩を明示30分に変更 | 19:00 | 実働7時間見込み。ただし休憩記録の確認は別表示 |
| 上記で「今帰る」 | 18:10 | 既に記録した実働6時間40分。未取得休憩を控除しない |

Detailed rationale: `FORECAST_SEMANTICS.md`, `NOTIFICATION_POLICY.md`.

## v0.7 store-wide invariants
- アプリ全体のcatalog（active ID、store epoch/revision、全workday envelope/監査）を単一のトランザクションで保存する。workday単位の原子性だけでなく全体の最大1active・区間非重複を保つ。
- 全削除と通常更新を直列化し、古いepochの再保存・バックアップ自動復元を拒否する。データ削除未完了は明示する。
- 計算層の `WorkBounds` は確認済み下限、可能性上限、attainment、crossingを別々に持つ。possibleならcrossingは保証されずunavailable。reachedならexact/range。

### Timeline normalization contract
- Effective recorded intervals are globally disjoint within the day; completed intervals are positive and cannot end in the future. A single final open work/rest interval may have zero elapsed seconds at the observation Instant. An open gap is invalid.
- Observation gaps have valid, nonfuture endpoints; overlapping or touching gaps are unioned before intersection with work. They do not change actual rest or explicit nonwork gaps. An invalid clock endpoint fails calculation rather than fabricating a span.
- Remaining rest is derived from total recorded rest or the overlap of recorded rest with the explicit anchor-to-now window, including elapsed open rest. No negative remaining rest.

## v0.8 ordinary commands (initial pure aggregate)
- `WorkdayCatalog` の通常コマンドは `clockIn(id,profile)` / `startBreak` / `endBreak` / `clockOut(confirmBreak)` / `resume(id)`。入力には選択した実績Instant、信頼済みnow、期待catalog revisionを渡す。
- 同時刻の開区間開始は許可するが、その区間の閉鎖には開始より後の秒が必要。ゼロ長閉区間、未来、開始より前の閉鎖、重複UUID、後続勤務を持つ日への再開はエラー。通常の新規作成は最新終了時刻以降のみ、古い履歴の挿入は訂正機能へ分離。
- 受理した操作だけcatalog revisionを1増加。変更された日にはそのrevisionを記録する。未受理操作は値全体を変更しない。終了済みのsnapshotは退勤Instantで固定する。
- 今回の実装はメモリ内の純粋な値型であり、永続化・複数プロセス排他・削除epoch・監査・履歴訂正を実装したものではない。時計の信頼性は呼出元で確認し、観測空白は信頼済みnowに対して妥当性を検査後、閉じた勤務日の実績終了時刻へclipする。終了後だけの観測は実働へ影響させない。タイムゾーン/論理開始日と参考時刻、当日休憩overrideの保存は未実装（既存Timelineの計算は利用可能）。

### Catalog-integrated uncertainty review
- `reviewVersion = (catalogRevision, observationGeneration)`。新規観測の受理では観測世代のみ増加し、実績訂正では両方を増加。重複範囲のみの観測はno-op。観測書込みの対象は現在activeな日。
- `previewReview` は対象日とversion、訂正前後の区間・観測を返す。 `commitReview` は現在時刻で計算をやり直し、両世代と前後証跡が一致した場合に限りその日・観測・監査を値型として一体更新する。未来・時計逆転・競合・範囲不正は拒否し状態を変えない。
- 明示解決済み範囲は同じ日の新しい観測から除く。新規観測で実績訂正を上書きしない。過去のended日への訂正は現在activeな日に影響しない。アプリの計算はcatalogのsnapshotを使用して観測を見落とさない。
- 永続化・削除epoch・監査の耐障害性・他プロセス排他、解決済み分類の再訂正は未実装。観測の理由や信頼された時計のadapterも残る。

## 記録済み休憩終了の訂正（AC-10の保存基盤）

隣接する閉じた休憩と勤務の共有境界だけを前後に変更する。ゼロ長・未来・非隣接・要確認区間との交差は拒否し、勤務日の開始・終了・状態・予定休憩・他勤務日は維持する。確認時は両Domain世代、store epoch/revision、保存済みsnapshotと訂正前後を照合する。監査の由来はrecordedRestEnd、CSVではrest_end_correction（列構成は維持）。新journal eventは旧版で読めないため更新後のダウングレードは禁止。UIの明示確認・通知再計算・AC-10全体の受入は後続。最新CI未確認。

### 過去勤務日の記録済み休憩終了訂正

退勤済み履歴で明示選択した過去日も、同じ境界訂正の確認画面から訂正できる。最新勤務日とは別の対象日を明示し、履歴選択のepoch/revisionと勤務日の完全一致を照合する。現在勤務日・観測空白・通知の予定時刻は保持する（保存版の更新で通知予約IDは再調整され得る）。訂正後は旧履歴ページを失効させる。現在勤務中・休憩中・古い履歴選択の回帰試験を追加。CI・実機未確認。
