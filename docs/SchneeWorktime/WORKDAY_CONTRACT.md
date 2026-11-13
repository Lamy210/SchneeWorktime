# Workday Contract — SchneeWorktime v0.4

## Purpose
本書はOpenSpecの補足設計資料であり、実装コードではない。MVPの事実・予測・不明を混同しないためのデータ契約を明文化する。

## Canonical workday envelope
- `workdayId: UUID`: 明示的に作成した勤務記録の一意ID。日跨ぎで変更しない。
- `logicalStartDate`、`capturedTimeZoneID`: 勤務開始時に確定した表示/基準時刻の文脈。
- `profileSnapshot`: `dailyTargetSeconds=25200`、`expectedBreakSeconds=3600`、`referenceEndLocalTime=18:00?`。
- `state`: `notStarted | working | onBreak | ended`（各workdayの保存時はnotStarted無しでも可）。
- `workIntervals`、`breakIntervals`、`nonWorkGapIntervals`: half-open absolute intervals `[startInstant,endInstant)`。3つの種別は互いに重ならず、最後のアクティブ区間のみend=null可。
- `uncertainSpans`: 元の勤務区間に含まれ、勤務か非勤務か未確認のintervalとその観測理由。
- `futureRestPlan?`: 入力時の残り予定休憩秒数、入力時の休憩実績累積、入力Instantを保持。入力後に実際に取った休憩分だけ予定残りを減らす。実績休憩ではない。
- `plannedDepartureAt?`: 退勤予定。実際のclock-outと区別。
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
