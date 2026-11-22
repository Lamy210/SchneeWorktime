# Journal v2候補ファイル実体フェンス

## 目的
schema-2分離候補を生成した後、候補ファイルが同一byte列の別inodeに置換されても、追記時に新しく取得したファイルidentityだけでは置換を検出できない。元DBに対して#99で導入した永続化されない物理identityの記録と同様に、候補側の入替えも明示的に拒否する。

## 実装
- 候補を生成・独立検証した後で、候補ファイルの`DatabaseFileGuard.preservationIdentity`（dev・inode）を`JournalStagingCandidate.fileIdentity`に保持する。Snapshotから再構成せず、アプリ再起動後の自動再開は禁止。
- `appendOfflineFromPreservedSource`は追記前に保全済みファイルidentityと候補側の現在identityを比較する。不一致・リンク・sidecar・パーミッション違反は書込み前に拒否する。
- COMMIT後に候補実体が変化した場合は結果が不確定となるため、`committedButUnverified`として再試行を禁止する。原本Checkpoint・Journal側のフェンスは従来どおり。
- 回帰試験として、同じバイト列の別inodeへ候補を置換した場合に、移行候補も原本も変更せず失敗することを検証する。

## 限界
この値はプロセス内の証拠であり、暗号的真正性・ファイルハンドルの固定・採用時の原子的CAS・クラッシュ後再開を保証しない。呼出側は排他ロックを維持すること。v1.0リリースはNO-GOを維持。
