# Journal v2 元DBのファイル実体フェンス

## 背景

移行候補を作成・照合する間に、元DBが**同じepoch・revision・payloadを持つ別のSQLiteファイル**へ置き換えられる可能性がある。snapshot全bytesの再読込だけではこの差替えを検出できない。

## 実装

`JournalPreservedSourceCapture` により、最初の保全読込と再確認の双方でSQLiteファイルの `device + inode` を検証する。

- 読込直前の `DatabaseFileGuard.preservationIdentity` と、読込直後の実体同一性を検証する。
- 原本snapshot（epoch/revision/payload）を保持する。
- 候補生成後または候補照合後に同じ検査を繰り返し、snapshotまたはファイル実体が変化していれば拒否する。
- 同一bytesの別inodeは `DatabaseFileError.unsafeFile`、同じinodeでpayload/versionが変化していれば `JournalMigrationError.verificationFailed`。
- 事前検査は読み取り専用であり、候補採用や実行時のDB書換えを行わない。

## 安全境界

このフェンスは協調セッションロックの代わりではない。同一UIDからの非協調writer、原本差替え後に元へ戻すABA、検査後の入替、オープンしたfdの長期保持・原子的swapなどには対応しない。

**本番採用のGO条件は変わらない。** 排他ロックと原子的CAS、独立バックアップ、世代フェンス、障害復旧・ロールバックが別途必要。自動移行を有効化しない。

## 回帰

- 不変ファイルは通過する
- 完全bytesとsnapshotが同一でも別inodeへ差し替えた場合は拒否する
- 同一inodeでrevision/payloadが変化した場合は拒否する
