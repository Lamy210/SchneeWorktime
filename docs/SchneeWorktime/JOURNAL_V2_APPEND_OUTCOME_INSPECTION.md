# Journal v2: 不確定コミット後の読取専用結果照合

## 背景
SQLiteへの追記は、COMMIT後の再読込や原本の照合に失敗すると `committedButUnverified` を返す。例外発生だけを根拠に同じイベントを無条件再送すると、重複操作や履歴の損傷を招く。現時点では安全なライブ採用操作はなく、オフライン候補のみ対象とする。

## 実装
`JournalStagingDatabase.inspectUncertainOfflineAppend` は、候補作成時の原本capture・Checkpoint・両SQLiteファイルの物理identity・候補epoch・元イベント行の完全一致を `preflightPinnedCandidate` で読み取り専用で再照合する。

結果:
- `matchingAppendObserved(version)`: 期待Revisionの次に、試行したイベントと完全一致する行が存在する。観測した候補状態のみを表す。
- `appendNotObserved(version)`: 候補のRevisionが追記前と同じだったという観測。過去に一度も書かれなかった証明ではない。
- `indeterminate`: Revision飛び、異なるイベント、未来時刻の試行イベント、元DB/候補の置換・改竄・Checkpoint変化、読み込み失敗等を含む。安全側へ倒す。

**判定対象の制約:** `expected.revision` は候補作成時の `candidate.draft.candidateVersion.revision` と等しい場合だけ観測結果を返せる。候補生成後に一度でも追記済みの場合、その追記を含む直前prefixを固定した不変証拠が存在しないため、2回目以降の追記に関する照合は、現在の候補が一見整合していても `indeterminate` とする。Revision値だけでは過去イベント行の改変を否定できない。複数回追記の判定を行うには、試行前の完全な行BLOB群または強固なdigestと物理identityをバインドした個別のAttempt Receipt、排他制御および継続的な検証が必要。このPRでは再試行許可もAttempt Receiptも提供しない。

どの結果でもイベントの自動再実行・候補採用・原本変更は行わない。未来時刻（`event.now > now`）の試行イベントは、追記が見えない場合でも `appendNotObserved` にせず `indeterminate` にする。呼出側は排他ロックを保持し、時点の異なる観測を混同しない。クラッシュ後にcaptureを失った場合の自動再開も提供しない。

候補へ新規追記する `JournalRowCodec.encode` は、同じイベントから同じ行BLOBを再現できるよう `JSONEncoder` の `.sortedKeys` を指定する。SwiftのデフォルトJSONキー順序を前提としたバイト比較は不安定で、追記済みを誤って `indeterminate` とする可能性がある。既存schema-1の原本BLOB自体は変更しない。候補作成・再検査時の内部エンコード方式のみを固定する。

## テスト
追記なし、完全一致した追記、別イベントへの分岐、Checkpoint更新、unbound候補・別epochに加え、未来時刻の試行イベント、同一bytesの原本/候補inode置換、試行後の追加イベント、および同一イベントの繰り返しエンコードのバイト一致、および2回目の追記の成功済み・未試行をどちらも `indeterminate` とする境界を回帰検証する。CIでmacOS Worktime Domainテスト・Swift Quality・その他必須ゲートを検証する。

## リリース制約
このAPIは運用判断材料であり、障害復旧の完全実装ではない。原子的live切替、CAS世代フェンス、バックアップ・DR、Checkpointの新epochポリシーは未解決。v1.0はNO-GO。
