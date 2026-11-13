# PR #4 仕様レビュー記録 — 2026-11-13

## 範囲と目的
対象: https://github.com/Lamy210/SchneeWorktime/pull/4

今回の変更はOpenSpecと受入条件のみで、アプリ実装・法定残業判定・CIセキュリティポリシーの緩和は行わない。

## 発見事項と対応
| 重要度 | 問題点 | Spec対応 | 受入条件 |
|---|---|---|---|
| P0 | スリープ中の開いた勤務区間が確認なしで達成扱いになる | work-session / time-projection の未確認区間 | AC-43〜46 |
| P0 | OSに事前予約した時刻通知が「実績7時間達成」と誤読される | local-notifications 見込み/確定分離 | AC-50,51 |
| P0 | 休憩中退勤の状態遷移が曖昧 | work-session 休憩閉鎖を明示確認 | AC-41,42 |
| P0 | ID一致だけで旧時刻の通知が残る恐れ | local-notifications ID+trigger+revision | AC-52 |
| P0 | 保存成功後、通知予約前のクラッシュで古い通知が残る | local-settings-and-recovery 再収束 | AC-53 |
| P0 | 7時間未満で退勤しても未来カウントダウンが続き得る | time-projection 完了済み勤務日の凍結 | AC-48,49 |
| P1 | 基準終業時刻が休憩と重なる場合の挙動未明示 | reference-and-surplus 独立計算 | AC-54 |
| P1 | 通知頻度の上限・ロック画面での内容漏えい | local-notifications 上限制御と本文プライバシー | AC-55 |
| P1 | エクスポート先キャンセルを定義していない | local-settings-and-recovery | AC-56 |

## 設計上の制約
- 端末スリープ中の勤務継続はOSから確定できない。ユーザーの記録訂正と明示確認が必要。
- 予定休憩の60分はあくまで将来の見込みであり、取得済み休憩ではない。
- 事前に予約するmacOS通知は条件付き予測。確定達成は検証済み履歴から算定する。
- 清算期間や会社の正式な残業認定規則は未確認。日次目標420分超過を法定残業と表示しない。
- Appleのpending通知取消は非同期であり、厳密な一度だけの配信は保証しない。

## 公式情報
- OpenSpec spec-driven: https://github.com/Fission-AI/OpenSpec/blob/main/docs-lab/reference/schemas/spec-driven/index.md
- Apple UNUserNotificationCenter: https://developer.apple.com/documentation/usernotifications/unusernotificationcenter
- Apple wake: https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification
- Apple clock change: https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nssystemclockdidchange
- 厚生労働省フレックスタイム制: https://www.mhlw.go.jp/stf/seisakunitsuite/bunya/koyou_roudou/roudoukijun/flextime01.html

## 未検証事項
OpenSpec CLIによるstrict validation、Xcode/Swiftのビルド、macOS通知実機テスト。内容の静的検査のみでCLI実行結果を代用しない。

templateのRelease Isolation CI失敗は別のセキュリティ・テスト移植課題として分離する。

## v0.4 — 再レビュー追加項目

| 優先 | 問題 | 今回の対応 | 受入 |
|---|---|---|---|
| P0 | アプリ終了中の未観測時間を実働として扱い得る | active状態は復元し、観測できない区間を要確認とする | AC-57,58,75,82 |
| P0 | 日付を跨いだ「同一勤務日の再開」が曖昧 | UUID基準で再開し、後続勤務日がある場合は拒否 | AC-59,60 |
| P0 | 未来の時刻を実績へ保存できてしまう恐れ | actual timestampはnow以下、未来時刻は予定 | AC-61 |
| P0 | 未確認区間があれば常に目標未達/未確定とする単純判定が過剰 | 下限/上限を計算し到達の確実性と到達時刻の確実性を分離 | AC-62〜66,83 |
| P0 | 休憩予定の変更が実績休憩まで改変する恐れ | 当日予測専用overridesを追加 | AC-67〜69 |
| P0 | 未確認の目標を一意の時刻で予約してしまう | 時刻に幅があれば精密な通知を抑止 | AC-70,71,84 |
| P0 | 監査ログと勤務日を別コミットして一方だけ失う恐れ | per-workday原子的envelopeとrevision競合検知 | AC-72,73 |
| P0 | 全履歴削除時にbackupが残る可能性 | app-owned backups/logsを含む削除範囲を明確化 | AC-74,80 |
| P1 | 18:00基準の扱いとOS画面ロックの推測 | 基準時刻は無効化可能、screen lockから自動休憩しない | AC-76,77 |
| P1 | 許可取消・目標通知の多重配信の挙動が曖昧 | UIの達成確定とOS予測通知を分離 | AC-78,79 |
| P1 | 主画面で「最短」と「休憩込み退勤見込み」を取り違える | 退勤見込みを主表示、最短は副表示 | AC-81 |

### 設計上の反証と未確定
- **実働上下限は推測的推定であり雇用主による勤怠証明ではない。** 下限に含めるのはユーザーが確定した勤務記録だけとする。
- Macがスリープしても勤務継続した可能性はある。本人が明示確認または訂正するまでゼロ/全額を決めつけない。
- 実働下限が420分に達していれば達成自体は記録上確実だが、上限との差によって正確な達成時刻が範囲になることがある。
- Appleは未配信通知の照会と取消を提供するが、取消は非同期。OSの通知配信時刻・過去通知の完全取消を保証しない。
- 観測メタデータの記録間隔と端末負荷はMac実機で測定した後に決める。現時点では性能SLO unknown。
- 正式なフレックス清算、法定残業、賃金は本件のMVP範囲外。

### 受入検証
- 仕様構造とID一意性の静的検査を実施。
- **未実施**：OpenSpec CLIでのstrict validate、Swift/Xcode、OS通知・スリープの実機テスト。
- CIの既知のRelease Isolation failureはテンプレート移植問題として別件で追跡し、安全策を無効化しない。

