# Journal v2候補のオフライン事前照合（読取専用）

既存のRepositoryを開いたり現行DBを再初期化せずに、保存済みschema-1原本ファイルと
隔離schema-2候補の一致を検証する内部APIを追加する。

`JournalStagingDatabase.preflightPreservedSource(at:candidateURL:now:)`

1. `SnapshotStore.readForPreservation` で原本を読取専用で検証し、完全snapshotを保持。
2. `JournalStagingDatabase.inspect` で候補を読取専用で検査し、原本epoch・revision・payloadの全bytesを照合。
3. 原本をもう一度読取専用で読み、変更されていないことを確認する。
4. 不一致・候補改ざん・別世代・非通常ファイルは拒否する。検査中にDBを書き換えない。

## 前提条件と未保証

- 呼び出し元は原本ファイルの所有権、プライベート保存先、および協調プロセス用のセッションロックを確保する。
- 2度の読取はTOCTOUを完全には排除できない。**本番採用時は原子的CAS・世代フェンスが必須**。
- 読取専用の**検査**であり、DBの入替・自動移行・復旧/ダウングレードを実行しない。
- 同一UIDの非協調writer、ディスク枯渇、電源断、デバイス障害、実機動作は別途検証する。
- v1.0のリリースGO判定は変更しない。

## 回帰テスト

- 正しい原本と候補の照合で両ファイルのbytesが維持されること
- 候補作成後の原本更新で不一致となること
- 同一revisionでも異なるepochの原本を拒否すること
- 原本ファイルのシンボリックリンクを拒否すること
