# Forecast Semantics v0.6 — 時刻予測・試算の契約

## 位置付け
本書は `initial-worktime-mvp` のOpenSpecを補完する実装契約。実装コードではない。規範的要件は同changeの `time-projection` / `break-management` / `local-notifications` のScenarioを正本とする。

## タイムラインの分類
1. **確認済み実績**: ユーザーが入力/確認した勤務・休憩・非勤務ギャップ。
2. **要確認実績**: スリープ・強制終了・時刻異常で勤務実態が未確認の区間。実働の下限/上限として表示。
3. **将来仮定**: 以降の勤務継続、まだ取得していない休憩予定、任意の退勤候補。履歴の実績へ記録しない。

## 時刻の区別
| 値 | 定義 | 表示 |
|---|---|---|
| `earliestGoalAt` | これ以上休憩せず連続勤務したときの実働420分到達 | 最短7時間 |
| `estimatedDepartureAt` | 残り予定休憩を全部取得する仮定で、実働420分を確保する時刻 | 休憩込み退勤見込み |
| `plannedDepartureAt` | ユーザーが明示保存した退勤予定時刻。達成/不足の見込みは別計算 | 予定退勤 |
| `referenceEndAt` | 勤務日開始時の設定に固定された任意の参考時刻（初期18:00） | 参考終業 |
| `achievedAt` | 記録の有効な解釈で共通して得られる最初の実働420分到達Instant | 記録上達成 |

全値は独立。いずれも給与・正式な法定残業認定には使用しない。

## Preview input
`workdayRevision, observedAtInstant, candidateDepartureInstant, knownWorkedRange, plannedFutureRestSeconds, currentState`

- `candidateDepartureInstant >= observedAtInstant` が必須。`==` は「今帰る」として許可し、未来休憩を引かない。
- `availableFutureSeconds = candidateDepartureInstant - observedAtInstant`
- 実現可能な前提: `0 <= plannedFutureRestSeconds <= availableFutureSeconds`。実際の休憩予定が時間帯指定された場合は、その配置も検証する。
- 実現可能・実現不能・算定不能を区別する。利用者が予定休憩を減らす操作を選ぶまで**予定を自動で短縮しない**。
- 未確認時間が存在するときは、残り実働や目標差分を上下限で表現し、単一の確定値を出さない。
- 試算は純粋関数であり `workdayRevision` や通知/実績を変更しない。ユーザーが明示保存する場合には、元revisionが最新かつ候補がまだ未来か再検証する。

## Example: invalid forecast
- 出社11:30、休憩実績0分、現在18:10。記録上の実働6時間40分。
- 退勤候補19:00まで50分、残り休憩予定60分。
- `50 < 60` なので**この予定のままの退勤は実現不能**。従来の「想定実働6時間30分」との計算は条件が矛盾するため、正式なプレビューには採用しない。
- 休憩予定を明示的に30分へ変更した試算なら、未来50分から30分休憩し20分勤務、合計実働7時間となる。ただし休憩の取得状況は別途確認を促す。

## Example: feasible forecast
- 出社11:30、現在12:00、休憩実績0分、残り休憩予定60分。
- 退勤候補19:00まで420分の未来枠へ60分の休憩を配置可能。
- 12:00時点で実働30分。未来の勤務360分を仮定して合計390分＝6時間30分（目標まで30分不足）。

## Future-rest override and history corrections
- `futureRestPlan` は予定入力時刻 `setAtInstant`、入力した残り休憩秒数とrevisionを保持。
- 予定入力後の休憩区間と `[setAtInstant, now]` の重なり秒数だけを `consumedBreakSeconds` として数える（区間が後で訂正されたら再計算）。
- `remainingRest = max(0, restSecondsAtPlan - consumedBreakSeconds)`。同じ区間は一度だけ算入する。
- 入力前の休憩を遡って訂正しても、入力後に取った休憩としてカウントしない。
- 既に実働目標達成が記録上確実なときは、予定休憩で「目標達成時刻」を後ろに動かさない。

## When to invalidate a preview
- 勤務日revision変更、休憩開始/終了/訂正、日次目標設定のactive適用、OS時刻異常、候補時刻の経過。
- 古い見込みを保存する操作を受け付けず、必ず最新状態から再計算する。
- アプリが停止中も通知によって残業/目標達成を証明できるわけではない。

## Verification
AC-105〜111、AC-118〜121、元のAC-93〜96に加え、境界 `candidate == now`、`plannedRest == availableFuture`、`plannedRest > availableFuture` をFakeClockで検証する。OpenSpec CLI実行は別途。
