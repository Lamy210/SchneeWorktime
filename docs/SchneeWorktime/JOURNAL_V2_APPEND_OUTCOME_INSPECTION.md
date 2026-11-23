# Journal v2: 不確定コミット後の読取専用結果照合

## 背景
SQLiteへの追記は、COMMIT後の再読込や原本の照合に失敗すると `committedButUnverified` を返す。例外発生だけを根拠に同じイベントを無条件再送すると、重複操作や履歴の損傷を招く。現時点では安全なライブ採用操作はなく、オフライン候補のみ対象とする。

## 実装
`JournalStagingDatabase.inspectUncertainOfflineAppend` は、候補作成時の原本capture・Checkpoint・両SQLiteファイルの物理identity・候補epoch・元イベント行の完全一致を `preflightPinnedCandidate` で読み取り専用で再照合する。

結果:
- `matchingAppendObserved(version)`: 期待Revisionの次に、試行したイベントと完全一致する行が存在する。観測した候補状態のみを表す。
- `appendNotObserved(version)`: 候補のRevisionが追記前と同じだったという観測。過去に一度も書かれなかった証明ではない。
- `indeterminate`: Revision飛び、異なるイベント、未来時刻の試行イベント、元DB/候補の置換・改竄・Checkpoint変化、読み込み失敗等を含む。安全側へ倒す。

**ReceiptなしAPIの制約:** `expected.revision` は候補作成時の `candidate.draft.candidateVersion.revision` と等しい場合だけ観測結果を返せる。追加で、試行したイベントの時刻順序・ドメイン上の操作妥当性・追記後のJournal再生整合性を固定済みの原本行prefixに対して読取専用で確認し、無効な試行を `appendNotObserved` と誤分類せず `indeterminate` にする。候補生成後に一度でも追記済みの場合、その追記を含む直前prefixを固定した不変証拠が存在しないため、2回目以降の追記に関する照合は `indeterminate` とする。複数回追記の結果を判定する場合は、後述のメモリ内Attempt Receiptを試行**前**に取得し、外部排他を維持して照合する。Revision番号だけでは過去の行BLOBの同一性を証明できない。どちらのAPIも自動再試行は許可しない。

どの結果でもイベントの自動再実行・候補採用・原本変更は行わない。未来時刻（`event.now > now`）の試行イベントは、追記が見えない場合でも `appendNotObserved` にせず `indeterminate` にする。呼出側は排他ロックを保持し、時点の異なる観測を混同しない。クラッシュ後にcaptureを失った場合の自動再開も提供しない。

候補へ新規追記する `JournalRowCodec.encode` は、同じイベントから同じ行BLOBを再現できるよう `JSONEncoder` の `.sortedKeys` を指定する。SwiftのデフォルトJSONキー順序を前提としたバイト比較は不安定で、追記済みを誤って `indeterminate` とする可能性がある。既存schema-1の原本BLOB自体は変更しない。候補作成・再検査時の内部エンコード方式のみを固定する。

## メモリ内Attempt Receiptによる複数追記の読取専用判定

`JournalStagingDatabase.captureOfflineAppendAttempt` は、試行**前**に、保持中の原本session/directoryロックのもとで候補の行BLOB全体を読み取り、原本と候補のidentity、元snapshot、元Checkpoint、候補epoch、試行前Revision、イベントの次行BLOBを`JournalStagingAppendAttemptReceipt`に固定する。候補がすでに1回以上追記された状態でも記録できるが、`expected`が最新Revisionでなければ失敗する。

Receipt取得は時刻上限・直前のイベントとの時系列順序だけでなく、対象イベントを複製カタログへ適用し、Journal全行を再生して同じ状態になることまで**読取専用**で事前確認する。無効な操作、過去へ戻るイベント時刻、古いRevisionではReceiptを発行しない。追記時にも別途同じ検証を行い、Receiptそのものは書込み認可を持たない。

`JournalStagingDatabase.inspectUncertainOfflineAppend(receipt, sourceURL: candidate: now:)` は、固定した行prefixと候補の現行行をバイト単位で比較し、原本・候補identityと元Checkpointも再確認する。指定イベントの行が直後の1件だけ増えていれば `matchingAppendObserved`、未変化なら `appendNotObserved`、異なるイベント・後続追記・inode置換・prefix改変等は `indeterminate`。

**制約:** Receiptは呼び出し側プロセスのメモリ内でだけ保持し、ディスクへ保存しない。プロセス障害や再起動で失えば復旧しない。最大64MiBの行prefixを一時的に保持し得るため、メモリ上限と性能の実測が必要。これは追記の成功確定・自動再試行許可・live DB採用・CAS世代切替を提供しない。captureからappend、inspectまで外部排他ロックを継続すること。Receiptなしの従来APIは引き続き初回の追記のみ判定する。

## 候補への追加行の時刻順序

独立した候補DBの再読込時にも、**旧schema-1の原本行prefixを除く追加行**は各イベントの `now` が直前イベント以上であることを検証する。実際のオフライン追記は既に時刻逆行を禁止しているが、別経路から候補SQLiteの行BLOBを書き換えられた場合も、独立検査がその不変条件を確認する。

旧原本のイベント時刻順序をこの追加チェックで書き換えたり遡及的に拒否したりしない。正常な原本でも候補追加行が逆行した場合は `JournalMigrationError.invalidEvent`、Receiptによる結果判定は `indeterminate` へ安全側に倒す。これは原本認証・自動再試行・候補採用の許可にはならない。

## 実際の追記経路との検証ロジック共有

`JournalStagingAppendValidation.validate` は、Receipt生成、Receiptなしの読取専用結果判定、SQLiteへの実際のオフライン追記の3経路で使用する。事前検証ではイベント時刻の上限と単調性、Revision/行数、ドメイン操作、監査用reviewVersion変更および全Journal再生結果を確認する。検証結果は次行のBLOBと次のカタログ状態をセットで返し、追記経路は同じJournalを2回再生しない。

検証後、実際の追記は引き続きSQLiteの `BEGIN IMMEDIATE` 内でRevisionと全行BLOBの一致を再確認する。事前検証結果だけを根拠に書込みの競合制御や原本のロックを省略してはならない。検証結果は原子的世代切替・ライブ移行・自動再試行の許可ではない。

## テスト
追記なし、完全一致した追記、別イベントへの分岐、Checkpoint更新、unbound候補・別epochに加え、未来時刻の試行イベント、同一bytesの原本/候補inode置換、試行後の追加イベント、および同一イベントの繰り返しエンコードのバイト一致、および2回目の追記の成功済み・未試行をどちらも `indeterminate` とする境界を回帰検証する。メモリ内Receiptを使った初回/2回目の成功と未追記、別イベント、後続追加、inode置換、およびReceiptなしAPIが時刻逆行・無効操作を判定不能として拒否する境界も検証する。CIでmacOS Worktime Domainテスト・Swift Quality・その他必須ゲートを検証する。

## リリース制約
このAPIは運用判断材料であり、障害復旧の完全実装ではない。原子的live切替、CAS世代フェンス、バックアップ・DR、Checkpointの新epochポリシーは未解決。v1.0はNO-GO。
