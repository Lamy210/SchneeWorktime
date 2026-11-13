# Verification Strategy — SchneeWorktime v0.4

## 1. Test layers
| 層 | 実行環境 | 主要検証 |
|---|---|---|
| Domain unit | SwiftPM + FakeClock | 実働・休憩・目標到達上下限・秒精度・DST・日跨ぎ |
| Application integration | FakeStore/FakeNotification/FakeSystemEvents | 状態遷移、revision競合、原子的保存、通知reconciliation |
| macOS adapter | Apple実機/CI | UserNotifications権限・予約・非同期取消、NSWorkspace睡眠/起床、NSPanel |
| Manual UX | 実機 + VoiceOver | 記録訂正、予測ラベル、画面切断、キーボード、ロック画面 |

## 2. Baseline cases
- AC-01〜32: 既存実働算術・予定休憩・定時の誤認防止。
- AC-41〜53: 休憩中退勤、スリープ未確認、見込み通知。
- AC-57〜61: アプリ終了・再開・日跨ぎ・未来実績の拒否。
- AC-62〜66: 勤務の上下限・到達時刻の範囲。最も重要な計算境界。
- AC-67〜69: 将来休憩予定上書きが実績に混ざらない。
- AC-70〜75: 不確定通知抑止・再計算・原子的保存・競合。
- AC-76〜84: 設定・省電力・通知・プライバシー・表示。
- それ以外の既存P1はリリース前QAで確認する。

## 3. Properties to verify
1. `0 <= knownWork <= possibleWork`; `0 <= remainingMin <= remainingMax`.
2. `remainingMin=remainingMax=0` whenever `knownWork>=target` and all intervals are temporally valid.
3. Closed workdays do not accrue hours after clock-out, including process restart or change in wall clock.
4. No future actual timestamp and no double active workday.
5. A correction never results in mismatched workday and audit revisions.
6. Forecast break override does not mutate recorded breaks.
7. Reconcile uses the committed latest revision and avoids stale/duplicate owned pending requests, as far as the OS can guarantee.
8. No official overtime/pay language appears as a calculation result.

## 4. Fault injection
- Crash during per-workday atomic write, disk full, invalid schema, backup restore, stale revision commit.
- Sleep/wake with open work and open break, app forced quit and resume, system clock rollback, timezone/DST transition.
- Notification authorization denied/revoked, request already fired during cancel, repeated schedule calls.
- Display disconnected, app panel hidden, multiple UI commands racing.

## 5. Acceptance gates (proposed, not tested)
- Every P0 numerical/state machine case passes deterministically. Each AC is linked to test ID.
- OpenSpec strict validation succeeds on exact PR HEAD (currently not executed).
- macOS real hardware QA demonstrates correct behavior; template-only CI green is insufficient.
- Runtime CPU/RAM/battery and app start-up are measured before quantitative performance thresholds are accepted.
- Template Release Isolation failure is corrected without relaxing security checks, in a separate change.
