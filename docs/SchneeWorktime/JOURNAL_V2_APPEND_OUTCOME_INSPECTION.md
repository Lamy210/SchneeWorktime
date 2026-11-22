# Journal v2: 不確定コミット後の読取専用結果照合

## 背景
SQLiteへの追記は、COMMIT後の再読込や原本の照合に失敗すると `committedButUnverified` を返す。例外発生だけを根拠に同じイベントを無条件再送すると、重複操作や履歴の損傷を招く。現時点では安全なライブ採用操作はなく、オフライン候補のみ対象とする。

## 実装
`JournalStagingDatabase.inspectUncertainOfflineAppend` は、候補作成時の原本capture・Checkpoint・両SQLiteファイルの物理identity・候補epoch・元イベント行の完全一致を `preflightPinnedCandidate` で読み取り専用で再照合する。

結果:
- `matchingAppendObserved(version)`: 期待Revisionの次に、試行したイベントと完全一致する行が存在する。観測した候補状態のみを表す。
- `appendNotObserved(version)`: 候補のRevisionが追記前と同じだったという観測。過去に一度も書かれなかった証明ではない。
- `indeterminate`: Revision飛び、異なるイベント、元DB/候補の置換・改竄・Checkpoint変化、読み込み失敗等を含む。安全側へ倒す。

どの結果でもイベントの自動再実行・候補採用・原本変更は行わない。呼出側は排他ロックを保持し、時点の異なる観測を混同しない。クラッシュ後にcaptureを失った場合の自動再開も提供しない。

## テスト
追記なし、完全一致した追記、別イベントへの分岐、Checkpoint更新、unbound候補・別epochの5件。CIでmacOS Worktime Domainテスト・Swift Quality・その他必須ゲートを検証する。

## リリース制約
このAPIは運用判断材料であり、障害復旧の完全実装ではない。原子的live切替、CAS世代フェンス、バックアップ・DR、Checkpointの新epochポリシーは未解決。v1.0はNO-GO。
