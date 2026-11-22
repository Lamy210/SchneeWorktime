# Journal v2 オフライン候補の追記・CAS試作

## 対象
既存schema-2の分離候補DBに対する検証用のイベント追加保存のみを提供する。本番DBの自動採用、schema-1原本の変更、実際の勤怠操作に接続することは行わない。

## 制約と不変条件
- 別途保全したschema-1の完全StoredSnapshotをアンカーとし、候補内部の旧payload、source epoch/revision、および元のイベントprefixの整合性を検証する。
- candidate_progressテーブルを最初の追記トランザクションで作成する。以前の候補に同テーブルがなければsource revisionを現在revisionとして扱う。source epoch/revision/payloadは更新せず、candidate epochも変更しない。
- SQLite BEGIN IMMEDIATEの中でcandidate revision/全行を再検査し、イベント追加とrevisionの更新を同時COMMIT。競合した期待revisionを拒否する。
- codecの暫定上限（100,000行、個別64KiB、総64MiB）、未来イベント、不正なDomain遷移、no-opの拒否を維持する。元の旧Journal全履歴を残し、候補の全イベントを再生する。
- COMMIT後の独立再検証に失敗した場合はcommittedButUnverifiedを返し、確認なしで再試行しない。
- 上記は候補内部の整合性保証であり、真正性・稼働DBへの採用権限ではない。外部の原本と、今後設計する原子的な採用フェンスが必要。

## 検証対象
観測と退勤を順序どおりに追加した候補の再読込、旧revisionの拒否、不正な休憩操作の完全非破壊、および独立2 writerが同一revisionで競合するケース。統合CI・実機は未確認。

## 未実装
ライブDBとの切替・checkpoint移行・追加後のバックアップ形式・誤り復旧・停電とディスク枯渇試験・性能計測。v1.0はNO-GO。
