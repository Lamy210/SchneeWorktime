# Tasks: SchneeWorktime initial MVP

## PR 1 — specification and foundation
- [ ] OpenSpec changeをレビューし、会社規則が不明な項目は未確定のまま明示する
- [ ] `openspec validate initial-worktime-mvp --strict` を実行して警告ゼロを確認する（CLIバージョン差はヘルプ確認）
- [ ] 新規Swift 6 macOS app target, local SwiftPM domain/application targetsを作成する
- [ ] `Lamy210/template` の品質CIを実際のScheme/Packageに結線する。空のtemplate fixtureだけのgreenを「アプリ検証済」と扱わない

## PR 2 — pure domain
- [ ] 区間モデル、状態遷移、logical workday、UTC instant, timezone policyを実装
- [ ] 420分の計算、実績/予測分離、2種類の目標時刻、未確定を実装
- [ ] 基準18:00と日次超過を独立計算。法定残業用の型・文言を導入しない
- [ ] FakeClockで代表値、秒境界、日跨ぎ、DST/時刻逆行を検証

## PR 3 — application/persistence
- [ ] 明示打刻とCorrection revision、履歴全体の検証と監査ログ
- [ ] Atomic保存・版管理・失敗回復・破損退避・復元を実装
- [ ] 退勤後の凍結、再開、長時間未終了とスリープ時の要確認
- [ ] エクスポートと確認付き全削除を実装

## PR 4 — macOS UX
- [ ] メニューバー操作、設定、NSPanel、位置/透明度/前面表示
- [ ] 実績/予定/未確定を独立した視覚ラベルにする
- [ ] VoiceOver、キーボード、Reduced Motion、失われたモニター位置を検証

## PR 5 — OS notifications
- [ ] Permission、pending requests adapter、決定的logical ID、future-only計画
- [ ] committed revision後のcancel/add/reconcileと失敗時再試行
- [ ] 休憩修正・再起動・時刻変更・達成・退勤で取り消し/再作成
- [ ] OSの実配信時刻とstrict exactly-onceは非保証と文書化

## PR 6 — QA and release
- [ ] docs/SchneeWorktime/ACCEPTANCE_MATRIX.mdのP0全件を自動テストとマッピング
- [ ] 端末のsleep/wake、通知拒否、長時間稼働、位置復元をmacOS実機確認
- [ ] 用途と費用に合わせて配布（ad-hoc/署名/公証/Homebrew）を別途決定
- [ ] CIで真正のアプリビルド・テストを合格させる
