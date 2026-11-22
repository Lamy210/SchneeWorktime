# Journal v2候補追記の保全元フェンス

保全元schema-1のJournalだけでなくCheckpointの更新を追記開始前後に検証する内部PoC。#94～#96に依存する。稼働中のDB切替や候補採用は実装しない。

- 移行元ファイルをSQLite READONLYで再読込し、ファイルidentity、完全Journal snapshot、Checkpointの内容を取得・検証する。
- 候補のアンカーが`unbound`なら拒否。候補の元snapshotとcheckpointAnchorが保全元に一致し、期待候補Revisionも一致した場合のみ内部`appendOffline`で追記を実行する。
- 追記前後に移行元を再確認する。追記後の検証に失敗した場合は`committedButUnverified`として無条件再試行を禁止。
- 回帰試験: 有効な候補へ観測・退勤を追記し原本保持、同一RevisionでCheckpoint更新された候補の拒否、アンカーなし候補の拒否、元Journal変更時の拒否。

**制限:** 呼び出し元による排他ロックが必須。前後の照合だけでは原子的なlive CAS採用にはならず、検証後に元DBが更新されるTOCTOUを排除しない。アプリの勤怠操作に接続しない。Checkpointを勤務実績として再束縛しない。復旧・DR・異常終了テストは別途必要。v1.0 NO-GO。
