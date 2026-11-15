# Spec Delta

## Purpose
記録された区間から実働と残り時間を秒精度で算出し、連続勤務ならいつ到達するかと、予測休憩を取る場合の退勤見込みを別々に示す。

## ADDED Requirements

### Requirement: Exact net-work accounting
The system SHALL sum completed work intervals and one active work interval at current Instant, excluding break and ended gaps. It SHALL compute remaining=max(0,25200-worked) and surplus=max(0,worked-25200) for the default profile.

#### Scenario: Known break
- **WHEN** 11:30開始、12:00〜13:00休憩、現在18:10である
- **THEN** 実働340分、残り80分、実働目標超過0分となる

#### Scenario: At threshold
- **WHEN** 記録上の累積実働が25200秒に到達する
- **THEN** 残り0秒、日次目標達成へ遷移する

### Requirement: Two distinct target timestamps
The system SHALL distinguish earliestGoalAt=now+remainingNetWork under continuous future work from estimatedDepartureAt=earliestGoalAt+unrecordedExpectedBreak when forecasts are applicable. Both SHALL expose assumptions.

#### Scenario: No rest yet
- **WHEN** 11:30開始、休憩未記録、現在11:31、標準休憩60分
- **THEN** 実働残り6時間59分、最短達成18:30、休憩込みの退勤見込み19:30を別表示する

#### Scenario: Break completed
- **WHEN** 11:30開始、12:00〜13:00休憩、現在18:10
- **THEN** 最短達成と休憩込み退勤見込みはいずれも19:30となる

#### Scenario: Break ongoing
- **WHEN** 休憩中で終了時刻が不明
- **THEN** 両方の将来時刻を未確定とし、残り実働時間だけ表示する

### Requirement: Actual achievement supersedes plans
The system SHALL calculate a threshold crossing from validated recorded intervals, distinguishing verified achievement from an unreviewed provisional crossing.

#### Scenario: No break taken
- **WHEN** 11:30開始から無休憩で18:30になる
- **THEN** 実績として7時間達成を18:30に表示し、19:30の未達カウントダウンを残さない

#### Scenario: Later break
- **WHEN** 18:30達成後18:40に休憩へ入る
- **THEN** 実際の達成時刻18:30を保持し新たな未達通知を生成しない

### Requirement: Freeze on exit
The system SHALL freeze actual duration, achievedAt and reference delta at clock-out, and recompute them only after explicit accepted correction or reopening. It SHALL NOT keep incrementing closed workdays from wall time.

#### Scenario: Historical view
- **WHEN** 17:00退勤した日の履歴を21:00に開く
- **THEN** 実働・超過・基準定時差分は17:00に確定した値を表示する

### Requirement: Rounding and clock anomalies
The system SHALL use absolute seconds for calculations, ceil positive remaining time to minute displays and floor completed surplus; it SHALL reject negative durations or detect backward clock anomalies.

#### Scenario: One second left
- **WHEN** 実働25199秒である
- **THEN** 表示はあと1分、実働25200秒で達成とする

#### Scenario: Clock rewound
- **WHEN** 15:00開始後にOS時計が14:50へ戻る
- **THEN** 負の実働を計算せず、時刻異常の確認表示とする

### Requirement: Planned departure is hypothetical
The system SHALL compare a user-entered future departure Instant against projected net work and clearly mark its shortfall/surplus as a scenario, never an attendance record.

#### Scenario: 20:00 planned
- **WHEN** 11:30開始、12:00〜13:00休憩、退勤予定20:00、追加休憩なし
- **THEN** 見込み実働450分、日次目標超過見込み30分を予定として表示する

### Requirement: Provisional versus confirmed achievement
The system SHALL distinguish provisional from confirmed recorded achievement when unresolved intervals can affect goal attainment. It SHALL report attainment as certain if the verified lower bound alone meets the target, but SHALL NOT claim an exact crossing time if unresolved spans could move that time.

#### Scenario: Threshold includes unverified sleep
- **WHEN** 60分の未確認スリープを含む勤務記録が7時間相当の経過に到達する
- **THEN** 達成確定を表示せず「計算上の目標到達・要確認」とする

#### Scenario: Uncertainty resolved
- **WHEN** 利用者が要確認区間を訂正または明示確認する
- **THEN** 最初の累積実働420分の到達時刻を再計算し、確定可否を更新する

### Requirement: Ended workday remains frozen
The system SHALL freeze the final recorded work bounds and attainment status at clock-out, including possible attainment when unresolved spans remain. It SHALL NOT continue a goal countdown after clock-out.

#### Scenario: Clock out with shortfall
- **WHEN** 実働6時間30分で退勤が確定する
- **THEN** 「日次目標まで30分不足」と固定表示し未来の到達予測は表示しない

#### Scenario: Explicit resume
- **WHEN** 実働6時間30分で退勤した勤務日を利用者が明示的に再開する
- **THEN** 残り30分として新たな最短目標時刻を計算する

### Requirement: Bounded worked time under unresolved anomalies
The system SHALL derive work bounds L and U from verified work and potentially worked unresolved spans. Attainment SHALL be notReached when U < target, possible when L < target <= U, and reached when L >= target. Achievement time SHALL be exact only if invariant across valid resolutions; otherwise it SHALL be a range or unavailable.

#### Scenario: Possible achievement after unreviewed sleep
- **WHEN** 11:30に開始し16:30〜17:30が未確認、現在18:30まで勤務記録が続く
- **THEN** 確認済み6時間・上限7時間とし、目標は到達可能性あり・要確認、確定時刻は表示しない

#### Scenario: Goal certainly reached despite unreviewed sleep
- **WHEN** 同じ勤務記録が19:30まで継続し、16:30〜17:30だけが未確認
- **THEN** 確認済み7時間・上限8時間となり、7時間到達済みだが正確な到達時刻は18:30〜19:30の範囲として表示する

#### Scenario: Correct uncertain hour to break
- **WHEN** 上記の未確認16:30〜17:30を休憩へ訂正する
- **THEN** 実働の下限と上限は一致し、最初の7時間到達時刻は19:30となる

#### Scenario: Confirm uncertain hour as working
- **WHEN** 上記の未確認16:30〜17:30を勤務継続として確認する
- **THEN** 実働の下限と上限は一致し、最初の7時間到達時刻は18:30となる

#### Scenario: Anomaly occurs after goal was achieved
- **WHEN** 11:30開始、18:30に7時間到達後、19:00〜20:00に未確認区間が発生する
- **THEN** 18:30の到達時刻は維持し、未確認区間はその後の超過実働にのみ影響する

### Requirement: Forecast unavailable when bounds diverge
The system SHALL not present a single exact future target Instant when unresolved spans make multiple target times possible. It SHALL display remaining-work bounds and a review prompt until uncertainty is resolved.

#### Scenario: Uncertain time changes remaining
- **WHEN** 記録上の実働が6時間で、そのうち30分が未確認である
- **THEN** 実働の下限5時間30分・上限6時間、残り実働は60〜90分の範囲と表示し、単一の確定退勤見込みを表示しない

### Requirement: Forecast override is independent
The system SHALL include only explicitly forecast future break seconds when producing an estimated departure and SHALL NOT write forecast overrides into historical work or break intervals.

#### Scenario: Thirty-minute remaining break
- **WHEN** 11:30開始、未取得休憩60分で今後の休憩見込みだけを30分に変更する
- **THEN** 最短達成は18:30、休憩込み見込みは19:00、休憩実績は0分となる

### Requirement: Non-work gaps do not satisfy planned rest
The system SHALL exclude explicitly classified non-working gaps from both actual work and recorded break; unlike an actual break they SHALL not reduce the default remaining expected rest.

#### Scenario: One-hour non-working gap before the target
- **WHEN** 11:30出社、16:30〜17:30を非勤務ギャップと記録し17:30時点で休憩実績0分である
- **THEN** 実働5時間、最短達成19:30、既定の予定休憩込み退勤見込み20:30となる

#### Scenario: Same interval classified as an actual break
- **WHEN** 同じ16:30〜17:30を休憩として記録する
- **THEN** 実働5時間、休憩実績60分、最短達成と退勤見込みは19:30となる

### Requirement: Non-destructive leave-at what-if projection
The system SHALL calculate a hypothetical net-work result for a candidate departure Instant without modifying the canonical workday, actual end time, or persisted plannedDepartureAt. A user SHALL explicitly confirm if they want to save a candidate as a plan. The preview SHALL account for future planned rest and unresolved recorded intervals.

#### Scenario: Leave at 19:00 after recorded break
- **WHEN** 11:30開始、12:00〜13:00休憩済み、18:10現在で19:00退勤を試算する
- **THEN** 19:00の想定実働は6時間30分、日次目標まで30分不足と表示する

#### Scenario: Leave at 20:00 after recorded break
- **WHEN** 同じ勤務日で20:00退勤を試算する
- **THEN** 想定実働7時間30分、日次目標を30分超過すると表示する（正式残業認定ではない）

#### Scenario: Cancel hypothetical departure
- **WHEN** 19:00退勤の試算画面を閉じる
- **THEN** 記録済み実働・退勤予定・通知計画と勤務日revisionは変わらない

#### Scenario: Hypothetical departure with future break
- **WHEN** 11:30開始、現在12:00で休憩実績なし、残り予定休憩60分で19:00退勤を試算する
- **THEN** 残り7時間内に予定休憩60分を取得可能であり、想定実働6時間30分・目標不足30分と表示して将来休憩の仮定を明記する

#### Scenario: Uncertain past work in leave-at preview
- **WHEN** 過去の未確認時間がある勤務日で19:00退勤を試算する
- **THEN** 想定実働と過不足を範囲で示し、単一の確定値として表示しない

### Requirement: What-if feasibility is a precondition for numeric results
For an active workday, the system SHALL validate that a hypothetical future departure is not earlier than the observation Instant and forecast rest fits in the future window. A leave-now query SHALL ignore all future assumptions. It SHALL distinguish feasible, infeasible and unknown projections. It SHALL NOT silently clamp planned rest to the available horizon, generate negative future work, or claim a single precise result from unresolved work spans.

#### Scenario: Rest cannot fit before departure
- **WHEN** 11:30開始・休憩実績0分・現在18:10・残り予定休憩60分・退勤候補19:00
- **THEN** 未来の空き時間50分より予定休憩60分が長いため「この条件では実現不可」と表示し、想定実働6時間30分を有効な見込みとして提示しない

#### Scenario: Change break plan to fit candidate
- **WHEN** 上記の試算で残り休憩予定を明示的に30分へ変更する
- **THEN** 19:00までに30分の休憩が収まり、見込み実働7時間・日次目標との差0分と表示するが休憩要件の確認は別に促す

#### Scenario: Departure before current time
- **WHEN** 現在18:10で退勤候補18:00を入力する
- **THEN** 未来予測として扱わず、入力を拒否または履歴訂正へ案内する

#### Scenario: Departure right now
- **WHEN** workingで現在18:10に「今帰る」を試算する
- **THEN** 将来休憩を勝手に控除せず現在までの実績を基に過不足を示し、実績は変更しない

#### Scenario: Short horizon with unresolved break
- **WHEN** 終了予定不明の休憩中に19:00退勤の見込みを要求する
- **THEN** 休憩終了が未確定と説明し、明示的な予定復帰時刻がなければ確定的な予測を出さない

### Requirement: Preview is bound to current workday revision
The system SHALL label each what-if result with the workday revision and observation Instant used to derive it. The system SHALL invalidate a shown projection when the workday changes or when its candidate Instant has passed, and SHALL require re-evaluation before saving it as an explicit planned departure.

#### Scenario: Break starts after preview
- **WHEN** 19:30退勤プレビューを表示した後に休憩開始が保存される
- **THEN** 古いプレビューを無効化し、保存前に新しい状態から再試算する

#### Scenario: Candidate passes while preview open
- **WHEN** 19:00候補の試算を開いたまま現在時刻が19:01になる
- **THEN** 19:00を新しい退勤予定としてそのまま保存させず、再計算または訂正へ誘導する

### Requirement: Desired departure is independent of feasibility
The system SHALL allow an explicitly saved future plannedDepartureAt even if its projection is infeasible or unknown, provided the warning is acknowledged. It SHALL preserve the user's intent, not change actual intervals or forecast rest, and never substitute the saved time for estimatedDepartureAt. A past or now candidate SHALL NOT be saved as a new future plan.

#### Scenario: Save infeasible desire
- **WHEN** 現在18:10に残り休憩60分のまま19:00の希望退勤を警告確認後に保存する
- **THEN** 希望19:00・目標達成見込み19:30・条件不整合を別表示し、希望を実績/有効な予報として扱わない

#### Scenario: Plan becomes feasible again
- **WHEN** 保存済み希望に対して利用者が予定休憩を変更し条件が成立する
- **THEN** 同じ希望時刻を保持したまま見込みを再計算する

#### Scenario: Passed desired time
- **WHEN** 19:00の希望を保存したまま19:01になる
- **THEN** 希望を過去の予定と表示し、退勤実績を生成せず未来通知も予約しない

### Requirement: Preview during an active break
The system SHALL accept an optional hypothetical return Instant for an active break, in the closed interval from now to candidate. The future active-break duration SHALL consume the remaining rest budget first; total future rest SHALL be max(mandatory active-break duration, remaining rest budget). It SHALL not save a break-end event from a preview.

#### Scenario: Return assumption consumes rest budget
- **WHEN** 11:30開始、12:00休憩開始、12:20現在、休憩実績経過20分、標準60分、13:00復帰仮定、19:30退勤候補
- **THEN** 残り休憩40分を一度だけ控除し、実働7時間見込みとする。休憩は実際には終了しない

#### Scenario: Candidate before hypothetical return
- **WHEN** 12:20休憩中で13:00に復帰する仮定、12:45退勤候補を指定する
- **THEN** 仮定と矛盾するため実現不能とする

#### Scenario: Leave now on break
- **WHEN** 12:20休憩中に今帰るを試算する
- **THEN** 現時点までの実働30分を表示し、未来休憩を控除しない

#### Scenario: Ended day projection
- **WHEN** 退勤済みの勤務日を閲覧する
- **THEN** 固定した実績の範囲を表示し、将来の退勤試算は明示再開まで無効とする

### Requirement: Forecast rest assumptions with unresolved history
The system SHALL compute future rest from recorded rest and explicit plans only, not speculative reclassification of unresolved historical work. It SHALL label the assumption and expose hypothetical work bounds under that assumption. A forecast range SHALL not silently become an exact prediction.

#### Scenario: Uncertain time could have been rest
- **WHEN** 過去60分が未確認で休憩実績0分のまま試算する
- **THEN** 未確認時間を休憩実績へ加算せず、予定休憩の根拠を示して実働範囲を返す

### Requirement: Normalize uncertainty without duplicate elapsed work
The system SHALL validate disjoint recorded work, rest and gap intervals and allow at most one final open work or rest interval. It SHALL union overlapping observation gaps, intersect them with work intervals only, and split work into verified and unverified spans without double counting. Invalid or future endpoints SHALL fail validation.

#### Scenario: Overlapping sleep and downtime
- **WHEN** two observation gaps overlap each other and intersect an actual break
- **THEN** their union intersects only recorded work, and the recorded break is counted once as rest

#### Scenario: Immediate clock-in
- **WHEN** an open work interval starts exactly at the observation Instant
- **THEN** the initial recorded work duration is zero without creating a zero-length closed interval
