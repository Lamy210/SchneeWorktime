# Journal v2 イベント行方式の移行候補（BUG-01 / P0）

## スコープと現在の制約
現行schema-1は10,000件/16MiBの単一payload。#83の読取専用保全で原本の確定Journalを取得できるが、完全枯渇からの退勤はできない。本PRは内部の移行draft/行codecのみ。永続化形式変更、live採用、UI、上限変更、退勤強制を行わない。既存OpenSpecのschema-1要件は維持する。

## 構成案
- schema-2候補はepochとrevisionを持つメタデータ、および連続する1始まりのsequenceを主キーとしたイベント行。1イベントにつきJSONのBLOBを1件保存する。既存JournalEventの型とDomain再生規則を再利用する。
- 旧Journalは通常のCatalogBackup検証で先に検証し、source epoch/revision/payloadの完全bytesを保持する。再エンコードされた行は元イベントと等価であること、全catalogの値が等価であることを確認する。元のpayloadは破棄しない。
- 新epochの候補と連続sequenceを作る。候補の確定・採用・切戻しは未実装。オフライン候補の比較に旧checkpointを直接信用して実働を加算しない。
- 暫定のcodec検証境界は100,000行、1行64KiB、総64MiB。これは本番容量値の決定ではなく、巨大/破損入力への限界を持つための仮定。DB読込時の事前制限、計測、退勤枠、実容量、バックアップ形式は別途設計する。

## 次の永続化契約（未実装）
BEGIN IMMEDIATE内で旧epoch・revisionと必要な原本同一性を確認し、イベント行とメタデータを一体で確定。sequenceの欠落・重複・順序不一致、未知イベント、未来イベント、no-opは拒否。単一writerと排他ロック、旧世代拒否を維持する。移行は必ず別のprivate directoryに作成し、元schema-1の完全保全・候補の再open/全値照合後に明示採用する。採用フェンスとクラッシュ復旧、checkpoint処理は独立して検証する。

## 検証
10,000件のactive旧Journalに監査を含め、行化後の全イベントと全catalogの等価性、追加観測と退勤の10,002件再生を確認する試験を追加。欠落・複製・並び替え・byte上限・未知/破損・未来・空データも検証する。再生のみで実際の退勤保存を行わない。性能、メモリ、実SQLite transaction、停電、ディスク枯渇、採用時の旧世代フェンス、古いアプリへのdowngradeは未検証。リリースNO-GO維持。
