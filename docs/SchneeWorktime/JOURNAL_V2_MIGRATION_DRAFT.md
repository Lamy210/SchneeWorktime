# Journal v2 イベント行方式の移行候補（BUG-01 / P0）

## 初回リリースの採用方針（2026-11-24）

v1.0未リリースのため、schema-1の後方互換および旧DBからの自動移行は**要件から外す**。v1.0正規保存形式は新規作成のschema-2のみ。旧schema-1DB、未知のschema、不正なDBを読み込んだときは上書き・削除・自動再作成せず拒否する。開発中の旧データは利用者の明示操作で保全できるが、自動引継ぎは提供しない。

`JournalV2LiveStore` は新規DBで `live_generation` + 行単位 `journal_event` の作成、Journal再生、全行bytes一致フェンスとepoch/revision CAS付きの原子的追記、論理reset（新epoch・全行削除）を実装する。別用途の `migration_source` を持つオフライン候補を正規ライブDBと見なさない。上限は仮に100,000行・1行64KiB・総64MiBで、長期性能・ディスク不足に対する実機計測は未完了。

**このPRでは `WorktimeController` はまだ既存schema-1ストアを呼んでいる。** 次段階でController/CatalogRepositoryの正式接続、schema-2の観測Checkpointと全操作の原子的処理、削除・バックアップ・復元・クラッシュ復旧を完成する。移行候補や旧epochからのadoptionは採用しない。新規ストアコアの存在だけでP0解除・リリースGOとはならない。

## スコープと現在の制約
現行schema-1は10,000件/16MiBの単一payload。#83の読取専用保全で原本の確定Journalを取得できるが、完全枯渇からの退勤はできない。後続PRでオフライン候補のSQLite追記・独立再読込・原本フェンス・不確定結果照合まで進んだが、live採用、UI、schema-1の上限変更、退勤強制は行わない。既存OpenSpecのschema-1要件は維持する。

## 構成案
- schema-2候補はepochとrevisionを持つメタデータ、および連続する1始まりのsequenceを主キーとしたイベント行。1イベントにつきJSONのBLOBを1件保存する。既存JournalEventの型とDomain再生規則を再利用する。
- 旧Journalは通常のCatalogBackup検証で先に検証し、source epoch/revision/payloadの完全bytesを保持する。再エンコードされた行は元イベントと等価であること、全catalogの値が等価であることを確認する。元のpayloadは破棄しない。
- 新epochの候補と連続sequenceを作る。候補の確定・採用・切戻しは未実装。オフライン候補の比較に旧checkpointを直接信用して実働を加算しない。
- 暫定のcodec検証境界は100,000行、1行64KiB、総64MiB。これは本番容量値の決定ではなく、巨大/破損入力への限界を持つための仮定。DB読込時の事前制限、計測、退勤枠、実容量、バックアップ形式は別途設計する。

## 新epochのCheckpoint引継ぎ条件（読取専用の一部を実装）

原本の `source_checkpoint` は移行の**参照アンカー**であり、候補epochの有効な勤務観測Checkpointではない。`JournalStagingDatabase.inspectCheckpointTransition` は、原本の物理identity・snapshot/Checkpoint・候補identity・Journal行prefixを再照合した上で、候補の現在状態に必要な次世代Checkpoint条件を返す。これは観測の実施・保存を行わない。

- 候補が終了済み（active勤務日なし）の場合、次世代のactive観測Checkpointは `nil` である必要がある。旧原本マーカーを残してはいけない。
- 候補がactive勤務中の場合、候補の**新epoch・最新revision・現在のdayID**が一致する新たな観測が必要。観測時刻は「原本マーカーの観測時刻」と「候補の最終イベント時刻」のどちらよりも後であり、確認時刻より未来ではならない。元epochのマーカー、同時刻の単純再ラベル、別勤務日のマーカーを拒否する。
- 検査が成功しても、OS/時計による新鮮な観測が実際に行われた証拠にはならない。外部排他、原子的な旧/新世代切替、Checkpointの同一トランザクション確定、既存アプリの旧世代書込拒否、クラッシュ後の再開/ロールバックは未実装であり、候補採用の許可トークンにしてはならない。
- 最終イベントより後の新観測が採取できない場合は移行を保留し、未観測区間を勤務実績として捏造しない。原本と保全コピーを維持する。

## 次の永続化契約（未実装）
BEGIN IMMEDIATE内で旧epoch・revisionと必要な原本同一性を確認し、イベント行とメタデータを一体で確定。sequenceの欠落・重複・順序不一致、未知イベント、未来イベント、no-opは拒否。単一writerと排他ロック、旧世代拒否を維持する。移行は必ず別のprivate directoryに作成し、元schema-1の完全保全・候補の再open/全値照合後に明示採用する。採用フェンスとクラッシュ復旧、checkpoint処理は独立して検証する。

## 検証
10,000件のactive旧Journalに監査を含め、行化後の全イベントと全catalogの等価性、追加観測と退勤の10,002件再生を確認する試験を追加。欠落・複製・並び替え・byte上限・未知/破損・未来・空データも検証する。再生のみで実際の退勤保存を行わない。性能、メモリ、実SQLite transaction、停電、ディスク枯渇、採用時の旧世代フェンス、古いアプリへのdowngradeは未検証。リリースNO-GO維持。
