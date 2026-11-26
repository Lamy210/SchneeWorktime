# schema-2正式UI接続までの起動フェイルクローズ境界（P0・PR #131）

## 目的

v1.0の初回公開形式はschema-2のみ。未完のschema-1専用`DesktopModel`/表示・確認画面へ、schema-2の正常DBや未知のDBを**取り違えて引き渡さない**。また配布ビルドから新しいschema-1 DBを作らず、開発用の既存schema-1を勝手に移行・上書きしない。

本PRは**本番UIのschema-2切替ではない**。切替完了前に誤った形式で稼働しないための安全な起動ゲート。結果として配布版で初回の勤怠操作はまだ開始できない。**v1.0 NO-GO**を明示的に維持する。

## 起動の判定表

| DBの状態 | DEBUGビルド | 配布用（非DEBUG）ビルド |
|---|---|---|
| DBなし・新規作成操作 | 従来のschema-1での開発作業のみ許可 | schema-2 UI未接続の案内を表示、**DBを作らない** |
| DBなし・再読込 | 新規データなしと表示 | 新規データなしと表示 |
| 既存schema-1 | 既存の開発用旧Controllerで作業可能 | **開かない/変更しない**。保存フォルダ全体の保全を案内 |
| 既存schema-2 | **旧Controllerを開かない** | **旧Controllerを開かない**。接続完了版を待つ案内 |
| SQLite `user_version`がそれ以外 | 開かない/変更しない | 開かない/変更しない |
| SQLite以外/破損ヘッダ/シンボリックリンク/ハードリンク/不正所有者・権限/ホットjournal | **読取検査失敗・起動停止** | **読取検査失敗・起動停止** |

## 実装境界

- `WorktimeDatabaseFormatProbe.inspect` は、正規化したパスの`lstat`と、所有者/単一ハードリンク/私有パーミッション/サイドカーが安全であることの検証後、`SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`と`query_only`で`PRAGMA user_version`だけを参照する。既存DBの生成、`BEGIN IMMEDIATE`、Checkpoint更新、Journal再生、移行、復元、破損DBの自動置換はしない。
- この検査によるschema-2判定は**ヘッダの形式候補の識別のみ**。Journal全行の整合性やデータ健康度を保証するものではない。将来の正式接続時は`JournalV2Repository`が厳密な再生/CAS・時刻検証を実施する必要がある。
- `DesktopStorageLaunchGuard`で配布用の旧形式作成を拒否し、開発用の旧形式許可を明示的に分離。`DesktopModel.open`は既存の`LocalSessionLock`を取得してからガードを呼ぶ。拒否時は`controller=nil`、`ready=false`を維持し、通知を不確実状態へ移して取り消し処理を要求する。**OS通知取消の完了は未保証**。
- schema-2に対しschema-1用の`PreservationBackup`を実行しない。原本ディレクトリの手動保全を案内。アプリ所有範囲外のコピー・外部のユーザーエクスポートを勝手に削除しない。

## テストと保留

`WorktimeDatabaseFormatProbeTests`でDBなし、旧DBバイト不変、schema-2 Journal/Checkpointバイト不変、未知バージョン、symlink/hardlink、hot journal拒否を検証。`DesktopStorageLaunchGuardTests`で配布版が新規schema-1を作らない、開発用の条件付き旧環境利用、schema-2の旧Controller拒否、破損DBの不変性を確認する。

**未完了:** schema-2本番UIの全操作接続（通常打刻・確認/履歴訂正/バックアップ・限定復元/削除/通知）、管理下バックアップ・診断データの完全削除とクラッシュ時の再開、電源断/容量枯渇/大容量の負荷試験、macOS実機・P0受入148件・RC証跡。配布版は意図的に機能制限中であり、公開不可。**NO-GO**。
