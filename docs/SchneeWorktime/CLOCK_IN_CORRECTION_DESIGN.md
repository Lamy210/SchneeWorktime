# 記録済み始業時刻訂正 — 段階設計

## 最初のスコープ
終了済み勤務日、先頭の閉じた勤務区間のみ。プレビューは値コピーで原本・revision・通知を変更しない。前日との半開区間境界、未確認区間、予定休憩anchor、捕捉参考時刻を検証する。捕捉情報なしの旧データは補完しない。勤務中の始業訂正、日付の再割当、休憩/非勤務で始まる履歴は後続設計。

## 永続化前に満たす条件
- StoreVersion / ReviewVersion / 完全snapshotを照合し、原子commitと新journal actionを追加する。
- 新旧のCapturedReference (nilを含む) と実績区間を監査に保持する。復元は送信時の解決結果を構造検証し、現在のtzdbで再計算しない。捕捉日・timezone・wall-time・resolutionの不変条件を検証する。
- 既存journalの形式・replay結果を変えない。新イベント使用後の旧版ダウングレードは非対応と明記する。
- 新しい監査originを区別し、始業訂正自体で将来の観測を抑制しない。現勤務日・checkpoint・通知は保存後の最新versionで更新する。
- 集計は既存仕様どおり選択tzと訂正済みstart Instantで再算定する。捕捉日は同じでも別tzで集計日が変わる可能性をUIで明記する。

## 検証
Domain preview 6件（PR #73の5 CI成功後main統合）。追加で予定休憩anchor、DST、旧データ、監査の連続訂正と再生、競合、バックアップ、後続勤務中のcheckpoint、CSV、通知、実機UIを検証する。Store/監査確定とjournal replayを追加し、CSVの14列は維持する。JSONには前後のCapturedReferenceを含む新イベントを保存する。Store回帰試験3件はHEAD aaee1dcbの全5 CI成功。再生時のtimezone非依存・後続観測の保持を含む5件はHEAD a6e6c4bdで全5 CI成功。旧参照なしの保存/復元と、同一StoreVersionでも元Journal bytesが異なる場合の確定拒否を検証する2件を追加（統合後CI未確認）。Application/UI・通知・実機QAは後続。新イベント保存後の旧版ダウングレード非対応。
