# Journal v2保全候補の元イベント行バイト整合性

## 脅威
元Journal snapshotと候補のevent列が同じイベントへJSON decodeできても、候補の元イベント行のBLOBバイト列は改変され得る。イベントの前に空白を加える等の改竄では、`JournalStagingDatabase.inspect`の意味的リプレイは成功し得る。候補作成時の原本由来イベント行を復元不可な形で守るため、追記前の独立検証では厳密な比較が必要。

## 実装
- 候補作成時のin-memory draft.rowsを信頼の起点とし、元イベントのすべての行（sequence と payload）のバイト単位の一致を確認する`preflightPinnedCandidate`を追加する。
- デバイス・inode・Checkpointのアンカーと候補epochも一緒に照合する。原本/候補identityを検査前後で照合する。
- 原本照合付き追記APIからこのpreflightを呼ぶ。追記済みイベントは元行prefixの後ろにのみ許可する。
- 正常な追記、JSONとして意味が変わらない改竄の拒否、source captureなし候補拒否を回帰検証する。

## 非保証
これはメモリ内の生成時証拠を使ったローカルの改竄検出であり、暗号的署名やクラッシュ後の永続的な真正性を保証しない。live DB採用・原子CAS・Checkpoint再束縛はしない。リリースはNO-GO。
