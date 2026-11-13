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
