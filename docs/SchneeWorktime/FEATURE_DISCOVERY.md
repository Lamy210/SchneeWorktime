# SchneeWorktime — Feature Discovery v0.5（候補と優先順位）

本書は**採用前の候補一覧**。OpenSpecのnormative Requirementとは別。MVP指定の一部は既存仕様、改善分は別途specへ明記する。
想定利用者：始業が変動するフレックス勤務、日次目標7時間、標準休憩60分、常駐Glass UIを望むmacOS利用者。

## Jobs to be done
- 出社した瞬間、今日の予定を立てるために退勤見込みが知りたい。
- 予定外の休憩や業務が発生しても、あと何分働けばよいか把握したい。
- 退勤したい時刻を仮入力し、日次の目標との差分を判断したい。
- 一度のタップで正確に休憩・退勤できるようにしたい。
- アプリが止まった後も時間を捏造せず、安全に勤務記録を復元したい。

## 採用判断基準
価値・実装負荷・プライバシー/誤表示リスクはそれぞれ1〜5の暫定評価（定量実測ではない）。MVPは価値の高さだけでなく実装可能性と安全性で決める。

| ID | 機能案 | 提案フェーズ | 価値 | 負荷 | リスク | 理由 |
|---|---|---|---:|---:|---:|---|
| F-01 | 休憩込み退勤見込みを主表示 | MVP | 5 | 1 | 1 | 予定が立てやすくなる。既存仕様 |
| F-02 | 今帰る/指定時刻で退勤した場合の不足・超過 | MVP | 5 | 2 | 1 | 実績と混ぜず瞬時に比較 |
| F-03 | 退勤予定を+15/-15分のワンタップ調整 | MVP | 5 | 2 | 1 | 日常操作が短くなる |
| F-04 | 未来の予定休憩を+15/-15分変更 | MVP | 5 | 2 | 2 | 既定60分の想定調整。実績へは反映しない |
| F-05 | 後から始業時刻を入力・訂正 | MVP | 5 | 2 | 2 | アプリ起動が遅れた日に使える |
| F-06 | メニューバーの最短操作 | MVP | 5 | 2 | 1 | 出社/休憩/退勤/履歴確認を素早く行う |
| F-07 | Glass表示のコンパクト/展開モード | MVP | 5 | 2 | 1 | 画面を邪魔しない |
| F-08 | 予定・実績・未確認の視覚的な区別 | MVP | 5 | 2 | 2 | 誤認を防ぐ。既存仕様 |
| F-09 | 30/15/5分前の選択式通知 | MVP | 4 | 2 | 2 | 毎日必要な通知だけ届く |
| F-10 | 通知権限の文脈付き説明 | MVP | 4 | 1 | 1 | 初回起動で押し付けない |
| F-11 | 中断・スリープ後の3分類確認 | MVP | 5 | 4 | 2 | 不確実な時間を正しく扱う。既存仕様 |
| F-12 | 1日終了時の結果サマリー | Next | 4 | 2 | 1 | 今日の実績/不足/超過がわかる |
| F-13 | 週の任意目標に対する累積実働 | Next | 5 | 3 | 2 | 週の見通し。ただし正式清算とは別 |
| F-14 | 日/週の勤務カレンダービュー | Next | 4 | 3 | 2 | 訂正と振り返りが簡単 |
| F-15 | 過去の出退勤パターンのプリセット | Next | 4 | 2 | 2 | いつもの始業・休憩をすぐ選べる |
| F-16 | 在宅/出社別の任意勤務プロファイル | Next | 4 | 3 | 2 | 制度が異なる日を手動選択 |
| F-17 | リマインダーの一時停止/スヌーズ | Next | 4 | 2 | 2 | 会議中の通知が邪魔にならない |
| F-18 | 休憩予定時間帯の事前指定 | Next | 4 | 3 | 3 | 12〜13時固定などを見込みに利用 |
| F-19 | 7時間未達での退勤時に不足確認 | Next | 4 | 2 | 2 | 誤退勤と意図的退勤の区別 |
| F-20 | 過去の出勤時刻・通知設定のテンプレート | Next | 3 | 2 | 1 | 設定し直しの手間を減らす |
| F-21 | App Intentsを通じてShortcutsから打刻 | Later | 4 | 3 | 3 | 外部ワークフローで開始/休憩を操作 |
| F-22 | WidgetKitでMacデスクトップ小型表示 | Later | 3 | 4 | 3 | Glassパネル以外の閲覧導線 |
| F-23 | Control Center/メニューバーControls | Later | 3 | 4 | 3 | 標準UIでのワンタップ操作 |
| F-24 | カレンダーから会議枠を参考表示 | Later | 3 | 4 | 5 | EventKit full access権限と保護が必要 |
| F-25 | 勤務記録CSVのインポート | Later | 3 | 3 | 4 | 会社側の入力形式や分単位丸め差を吸収 |
| F-26 | 週の予測退勤・不足シミュレーター | Later | 4 | 4 | 4 | 個人目標として表現し正式清算はしない |
| F-27 | コンテキストに応じた休憩提案 | Later | 3 | 4 | 3 | 強制ではない提案。健康管理を断定しない |
| F-28 | スクリーンアイドル検出 | Defer | 3 | 4 | 5 | 勤務とアイドルは一致せず権限・監視の懸念 |
| F-29 | 自動打刻/GPS/社内Wi-Fi連動 | Defer | 3 | 5 | 5 | 勤務実態を誤認しやすくプライバシー負担大 |
| F-30 | Slack/Teams通知連携 | Defer | 2 | 4 | 5 | 単体ローカル完結に反し得る |
| F-31 | クラウド/複数端末同期 | Defer | 2 | 5 | 5 | 認証/暗号化/同期競合が必要 |
| F-32 | 会社認定残業・割増賃金の計算 | Out | 2 | 5 | 5 | 清算期間と就業規則未確定、別製品仕様として検討 |

## 推奨初回リリース（Must have）
1. 退勤見込み/最短達成/残り実働を常時表示し、実績と見込みを明確にする。
2. 手動打刻と遡り始業入力、メニューバーでの素早い休憩・退勤。
3. 任意の退勤予定を試算（不足/目標超過）し、**試算は保存しない**。保存は明示操作。
4. 残り予定休憩の仮変更。実際の休憩の取得分だけ消費し、二重計上しない。
5. 参照定時18:00/目標420分/正式残業の境界を分離。
6. 終業の見込み通知、権限拒否・端末スリープ時の安全動作。
7. ミニGlass + 詳細Glass + メニューバー、表示切り替え。
8. ローカル永続化、訂正履歴、未確認区間の修正。

## 初回リリースに入れない条件付き機能
- 週目標（35時間など）はユーザー設定の**任意目標**であり、法定清算や会社の所定時間の算出ではない。週の表示は後続で採否を判断する。
- カレンダー同期はmacOS EventKitの許可を要する。勤務時間を自動的に確定できないため、当面は取り込まない。
- ショートカット連携はmacOS App Intentsで可能な範囲を検討する。Apple HIGによれば「App Shortcuts」はmacOS非対応であり、Macショートカットに組み込める**App Intents actions**とは区別する。
- デスクトップWidgetKitは可能だが更新タイミングやバッテリー制約がある。秒単位のGlass表示をWidgetへ置き換えない。
- キーボード/画面/アプリ監視による自動勤怠判定は、実働証明にならずプライバシー懸念が大きいので非採用。

## 公式/一次情報と競合の機能確認（2026-11）
- Apple MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
- Apple App Intents: https://developer.apple.com/documentation/appintents
- Apple App Shortcuts HIG: https://developer.apple.com/design/human-interface-guidelines/app-shortcuts
- Apple WidgetKit strategy: https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy
- Apple notification permissions: https://developer.apple.com/documentation/UserNotifications/asking-permission-to-use-notifications
- Apple EventKit permission: https://developer.apple.com/documentation/eventkit/accessing-the-event-store
- Toggl desktop app: https://support.toggl.com/en-us/article/toggl-track-desktop-app-for-macos-1669b8x/
- Timery: https://www.timeryapp.com/presskit.html

## Differentiation
汎用タイムトラッカーのタスク/プロジェクト課金管理ではなく、フレックス勤務者の「今日いつ帰れるか」「あと何分必要か」「これから休憩すると何時になるか」に即答できること。すべて手動/ローカル優先とし、正式な勤怠認定や給与計算とは区別する。
