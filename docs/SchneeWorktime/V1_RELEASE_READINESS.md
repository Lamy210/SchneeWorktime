# v1.0 リリース判定 — 2026-11-24

## 判定: NO-GO（検証未完了）

## 保存形式のリリース方針変更

未リリースのため、v1.0ではschema-1との後方互換、自動移行、ダウングレードを要求しない。初回公開時は新規schema-2 DBのみを正式形式とする。既存の開発用schema-1や不正なDBがある場合、データを無断削除・自動初期化するのではなく拒否し、利用者に明示保全を求める。schema-2専用のアプリケーション層セッションは用意済みだが、配布アプリのDesktopModelは依然schema-1に接続されており、P0は未達。



再監査の起点: main `741512de937dc71dfb7f0b01e929d9fccd643df6`（PR #109統合時点、後続のマージ後mainとは区別）。機能追加を凍結し、既存P0の達成、障害修正、配布検証を優先する。M1の集計は既に統合されているが、追加機能をM0リリース条件にしない。Developer ID/公証は必須とせず、ad-hoc署名と既存配布手順を維持する。

- [受入マトリクス](ACCEPTANCE_MATRIX.md): P0 148件、P1 24件。個々の試験との完全な照合は未完了。
- [OpenSpec tasks](../../openspec/changes/initial-worktime-mvp/tasks.md): 現時点のファイルでは87件中11件チェック済み、76件未チェック。チェック率を機能完成率とみなさない。
- PR #109のHEAD `f9c6063d0107038ab22a05ed53bd668d71158662` で Tests / Swift Quality / Quality / Secure File Identity / Release Isolation TDD の5件成功。Squash後のmain `741512de937dc71dfb7f0b01e929d9fccd643df6` 自体のpush CI証跡はこの監査では確認できていない。全P0達成・OS実機成功を意味しない。

## 既存実装の確認起点（個別ACの合格認定ではない）

| 領域 | 実装・試験を確認する起点 | 残る条件 |
|---|---|---|
| 通知 | #38, #41, #43, #45, #47, #49, #53 | 実機権限拒否、取消競合、再起動・起床・配信、AC全件対応 |
| 履歴訂正 | #44, #50、OpenSpec 17.6 | AC-155 は後続で勤務中の過去日訂正コード・回帰ケースを追加した記録がある。現在の統合挙動・QAの合否は未確認で、旧記述の「未実装」とは断定しない |
| 復元 | #36, #37, #45 | 同一世代の正常journalに限定。破損DBの保全・別世代の復旧、障害注入を別途検証 |
| データ削除 | AC-74, AC-134, AC-135, AC-158 | 論理resetの確認用APIと観測checkpointの同一トランザクション削除を追加。現在DB限定の明示確認UI・通知取消収束・保守排他・再読込を追加。内部backup/診断データ範囲と消去中断復旧、最新CI/実機検証は未完了。ファイルの完全消去を保証しない |
| 勤務予測 | #35, #40, #41, #42, #43 | AC-10/58の休憩訂正など、UIと永続化の受入条件を照合 |
| 常駐性能 | #46, #47, #48 | 実機測定未実施。10/100/500日のベンチマークと負荷QA |
| 配布 | #34、UNSIGNED_RELEASE.md | 最新mainの候補生成、ZIP/checksum、インストール、更新・復旧、実機QA |
| 振り返り（M1） | #51, #52 | 日週月/グラフ/CSVを統合済み。正式勤怠や給与計算ではない。実機QA未完 |

## schema-2の読み取り専用履歴UI（PR #132・検証中）

- 未接続のschema-2保存形式が見つかった場合、既存のschema-1 `WorktimeController`を利用せず、`JournalV2ReadOnlyInspection`と専用macOSメニュー画面で**保存済み勤務日/終了日/監査件数・最後の観測Checkpoint・最大30件単位の終了済み勤務履歴**を閲覧できるようにする。
- `JournalV2LiveStore.inspectReadOnly`は`SQLITE_OPEN_READONLY`・`PRAGMA query_only`・`BEGIN`でJournal全行を再生し、CheckpointとDB inode/owner/sidecarを前後検証する。読み込み時に`JournalV2WorktimeController`を生成しないため、**起動復旧、観測更新、勤務実績の追記、通知予約、削除、バックアップ作成を行わない**。
- ページングは毎回同じ形式で再読込み、途中でrevision/epochが変化した場合だけでなく、同じrevisionでCheckpointだけ変更された場合も`stalePage`で拒否。勤務中と記録されていてもリアルタイム観測・勤務継続の証拠にはならない旨を表示する。
- 既存の編集・確認・バックアップ・ロールバック・全履歴削除UIは**schema-2表示時に隠す**。開発版schema-1用の画面・操作は従来どおり隔離する。
- **P0残存:** schema-2の書込みを伴う正式UI接続（打刻/休憩/訂正/予定/通知/バックアップ/限定復元/全消去）、管理下ファイルの削除と中断復旧、macOS実機/障害注入/受入証跡は未完。初回配布可能な状態を意味しない。**v1.0 NO-GO**。

## 配布版の安全な起動経路（PR #131・schema-2 UI未接続）

- `DesktopModel.open`が既存のsession lock取得後、`WorktimeDatabaseFormatProbe`の読み取り専用SQLite形式判定と`DesktopStorageLaunchGuard`を実行する。schema-2/未知・破損DBを**schema-1の旧Controllerへ渡さない**。
- **配布版（非DEBUG）のschema-1新規作成・既存schema-1書込みを停止**。旧形式の開発データは移行/消去せず原本保全を要求。DEBUGは既存の旧形式での開発・テストを明示的に続行できる。schema-2のデータを旧形式の保全エクスポート処理へ渡さない。
- これは**安全な停止条件のみ**。配布版はschema-2の通常UI実装が完了するまで**新規利用者も既存schema-2データも操作不能**であり、初回配布に必要な機能を満たさない。安全な停止をリリース達成と混同しない。詳細は[起動ゲートの仕様と回帰試験](SCHEMA2_DESKTOP_STARTUP_GATE.md)。v1.0 **NO-GO継続**。

## schema-2アプリ接続の段階的準備

PR #117・#118によりschema-2イベント行ストアと観測Checkpointのトランザクション処理を内部実装済み。後続PRでは `JournalV2Repository` を追加し、打刻・観測・予定変更・Checkpoint・削除プレビューをアプリケーションから利用可能なAPIとして分離する。リビジョンが同じでもCheckpointだけ変更された場合、旧セッションの再利用を拒否する。

**このAPIを追加しても、現行の`WorktimeController`は依然schema-1の`CatalogRepository`を使用する。** 既存の履歴訂正・復元・CSV/バックアップ・起動時復旧を一度に置換せず、schema-2での同等機能の実装・試験を進めてからControllerの本番接続を変更する。未リリースのためschema-1への後方互換や自動移行は不要だが、開発用既存DBの無断消去は禁止する。

## schema-2アプリケーション層セッション（段階的移行・検証中）

- `JournalV2WorktimeController`を`WorktimeApplication`に独立追加。新規schema-2 DBのみを開き、`ClockSample`の単調時刻/壁時計検証、起動時に観測できなかった稼働区間の不確実記録、打刻・休憩・再開・定期Checkpoint、バックアップ・CSV保存を`JournalV2Repository`経由で実行する。
- 新規勤務開始・休憩終了・勤務再開では、打刻イベントと初回観測CheckpointをSQLite同一トランザクションへ記録する。スリープ/観測欠落からの復帰時も不確実区間のイベントと観測時刻を同一トランザクションに書く。schema-2のフルJournal/Checkpoint CASで古いセッションを拒否する。
- `JournalV2WorktimeControllerTests`で基本打刻/新100,000行容量ビュー/ギャップ処理/起動復旧/休憩とCheckpoint/時計逆行/CAS競合/旧schema-1原本保全/出力の検証を追加する。
- **本番切替ではない**。既存`WorktimeController`と`DesktopModel`の通常UI・履歴訂正/復元/削除/通知の接続はschema-1のまま。機能同等性、ロックの所有、旧テストのschema-2への全面移管、障害注入、実機QA後に正式切替する。v1.0は引き続き**NO-GO**。

## schema-2の全履歴削除・限定復元のアプリ層接続（PR #127 検証中）

- `JournalV2WorktimeController`へ`previewReset/commitReset`を追加し、時計の検証、プレビュー後の厳密なJournal全行/Checkpoint CAS、新epochへの切替を公開する。正常commit後は**このアプリセッションの状態も即時に新epochへ更新**し、消去した履歴を表示し続けない。
- `previewRollback/commitRollback`もアプリ層へ追加。正常・同epochの過去の終了済みprefixに限定し、DB外の所有者専用保全先へ現世代を排他保存/読戻ししたうえで新epochへ復元する。保全できない場合は書き換えない。
- 同revisionのCheckpoint競合、旧epochバックアップの拒否、異常時の原本保全、時計逆行、成功後の再起動での新epoch読み込みを回帰試験する。削除対象の暫定インベントリと障害境界は [SCHEMA2_RESET_SCOPE.md](SCHEMA2_RESET_SCOPE.md)。
- **未完:** `DesktopModel`と既存`WorktimeController`はschema-1経路のまま。schema-2用のUI確認・通知停止、アプリ管理バックアップ/診断ファイルの削除と中断再開、実機/電源断QA、全P0の受入証跡は未完。論理削除を物理消去と誤認しない。**v1.0 NO-GO**。

## schema-2の履歴/集計/通知・予測のアプリ層機能差分（PR #128）

- `JournalV2WorktimeController`から、履歴ページング、日週月集計、集計CSV、休憩予定変更と読み取り専用の通知計画を利用できるようにする。旧schema-1を読み込まず、同じ`WorktimeHistory`投影処理を共有する。
- 履歴/集計/通知計画を表示する前に全Journal行とCheckpointをrevalidateし、ページ継続時にversionが違う場合は拒否する。通知計画は時計異常や15秒を超える未観測ギャップでは返さない。
- 勤務中の休憩見込み変更はJournalと新しい観測Checkpointを同一SQLiteトランザクションに書く。休憩中は勤務観測を新規作成しない。変更なし要求でもCASを検証する。
- [2026-11-25リリースブロッカー再監査](RELEASE_BLOCKER_AUDIT_2026_11_25.md)参照。**本番`WorktimeController`/`DesktopModel`はschema-1のまま**。レビュー/履歴訂正・予定退勤・外部エクスポートなどの全機能の切替、削除の完全性、RC/実機・P0証跡は未完。**NO-GO継続**。

## schema-2の予定退勤・過去時刻始業（PR #130 検証中）

- `JournalV2WorktimeIntent.swift`に、過去時刻での始業の非破壊プレビューと明示確定を追加。単調時計の異常、古いepoch/revision、並行打刻、既存終了日の時刻との重複、100,000行上限に伴う開始容量不足を拒否する。**過去区間はユーザーによる明示的な勤務申告であり、アプリの観測事実ではない**。確定した始業イベント（過去の開始時刻）と、実際に押下した時点の最初の観測CheckpointをSQLite同一トランザクションに保存する。
- 希望退勤は勤務実績や退勤打刻と混同せず、事前の予測評価と必要時の警告確認を必須とする。確定時に現在の予測と確認条件を再計算し、古い確認案や観測ギャップを拒否。勤務中は予定変更イベントと新しいCheckpointを原子的に保存し、休憩中に偽の勤務観測を作成しない。
- 同じ希望退勤の再設定と解除済みの再解除は、新規Journalイベントを追加せず完全なJournal/Checkpoint CASを再検証する。設定解除で通知基準を自動見込みへ戻せるが、予約済み通知の取消と再登録自体は依然UI統合側が責任を持つ。
- **P0残存:** `DesktopModel`と従来の`WorktimeController`はschema-1を継続利用中。schema-2用の表示・確認UIと通知の排他所有、管理下データ削除中断復旧、破損DBや最大容量の負荷・OS電源断試験、RC/実機QAと受入証跡は未完。**v1.0 NO-GO**を維持。

## schema-2訂正操作のアプリケーション層接続（PR #129 検証中）

- `JournalV2WorktimeController`へ、既存のschema-2 `JournalV2Corrections`を使用する監査付きプレビュー/確定APIを追加。観測欠損区間のレビュー、休憩開始/終了境界、出勤/退勤時刻の変更を扱う。変更前後の`WorktimeGlance`を提示し、ユーザーの明示確認前には書込しない。
- 選択した過去日と表示中の履歴はepoch/revision・元Workdayに紐付け、古い表示や別セッションからのCheckpoint-only更新をDB全行/Checkpoint CASで拒否。勤務中の過去日訂正をコミットする場合、**監査イベントと現在勤務中の観測Checkpointを同じSQLiteトランザクションで保存する**（休憩中・終了済みはCheckpointを生成しない）。
- 訂正前/訂正後の見込み、出勤時刻訂正の期間集計影響をプレビューに含める。異常な壁時計、15秒超の観測ギャップがある場合は非破壊で拒否する。未確認の勤務時間を訂正だけで確定しない。
- **残るP0:** 現行`DesktopModel`はschema-1 `WorktimeController`を使用。通知のキャンセル/再予約と履歴訂正UIの統合、予定退勤/過去始業のアプリ層差分、管理下全ファイルの削除・破損DB/容量限界、実機と受入証跡は未完。v1.0は引き続きNO-GO。

## schema-2のレビュー・履歴訂正API（段階的実装）

`JournalV2Corrections` はschema-2 `JournalV2Repository`に対し、観測欠損のレビュー、休憩開始/終了境界の訂正、過去の出勤/退勤時刻訂正を追加する。全操作は「読み取り専用のプレビュー → 元Journal行・カタログ・Checkpointを完全一致検査 → ドメインによる確認結果の再計算 → 監査イベント1件の原子的追記」を経る。別操作・epoch reset・同revisionのCheckpoint更新が起きれば古いプレビューは拒否する。原本イベントを削除・書き換えない。

**留意:** アプリ`WorktimeController`、バックアップ/復元、CSV、削除範囲、OS時計の実機観測の正式接続はまだ旧形式であり、これらのAPIを追加してもv1.0をGOにはできない。CIのテスト成功は本番動線の確認を意味しない。

## schema-2バックアップ対応の暫定範囲

- `JournalV2Repository.makeBackup/writeBackup` は、現行epoch/revision・全イベント行bytes・再生catalog・観測Checkpointが一致するセッションからのみ、schema-2専用JSONバックアップを作成する。
- `JournalV2Backup.inspect` はschemaVersion=2のイベント行を**読み取り専用**で再生検証する。schema-1用の`CatalogBackup`形式は自動受入しない。バックアップにCheckpointを含めず、観測時刻を勤務実績として誤用しない。
- `BackupFile`の安全な排他書込（私有ディレクトリ、600モード、fsync、既存ファイル上書拒否）を維持し、**schema-2 JSONのみ96MiB**の上限を明示的に適用する。schema-2 Journalの64MiB行本体をBase64化したJSONは構造上96MiB以内に収まる。既存のschema-1・CSVは24MiBのまま。96MiB超は拒否する。最大データ量の実測、メモリ使用量、ストリーミング/ディスク満杯の障害試験はP0として未完了。
- アーカイブは署名済み証跡ではなく、内容が他者に変更されていない保証はない。復元時には別途、原本の明示保全、同一/別epochルール、atomic commitとクラッシュ復旧が必要。
- この段階では**自動復元・本番Controller接続をしない**。旧DBを変換・消去せず、v1.0はNO-GOを維持する。

## schema-2大容量アーカイブ対応の境界（PR検証中）

- schema-2イベント行の合計上限64MiB/最大100,000行をJSON Base64配列に変換しても、96MiBを超えない設計上の上界を採用。\`JournalV2Backup.maxBytes\`および専用\`BackupFile.publish/load(maxBytes:)\`に適用する。
- ファイル読込前のfstatサイズ判定と、64KiB単位のread中の上限確認を継続する。書込みはO_EXCL/O_NOFOLLOW/owner-only/fsyncで、新旧アーカイブが混在しても上書しない。
- **96MiBまでの上限緩和はストリーミング化ではない。** JSONエンコード/デコード時は全イベントとバイト列をメモリに保持する。最大64MiBでの負荷・RSS・電力・長時間動作の実測、クラッシュ/ディスク枯渇/復元の検証は未完了。初回公開のGO判定は行わない。

## schema-2 CSV出力の内部API

- `JournalV2Repository.makeCSV/writeCSV` はschema-2の完全一致セッション（epoch/revision、全Journal行、catalog、観測Checkpoint）を再検証してから、既存の14列CSV形式を生成・排他新規書出しする。補助Checkpointの時刻を勤務実績として追加しない。
- schema-1の`CatalogCSV.encode`は共通レンダラを使うだけで、既存のCSV列構成・出力内容は変更しない。CSVは診断・閲覧用途であり、**復元用アーカイブではない**。
- CSVの24MiB上限、Controller未接続、OS実機QA未完了は継続する。本APIのテスト成功だけでv1.0をGOにしない。

## schema-2限定ロールバックの内部実装（PR #124で統合済み）

- schema-2に対して、同一epochの厳密な過去Journal prefixのみを対象とする`previewRollback/commitRollback`を追加。現行・候補にactive勤務がある場合、分岐履歴、旧epoch、陳腐化した確認案は拒否する。
- 保存済み原本の完全なJSONバックアップをDB外の私有ディレクトリへ排他書出し・再読込検証してから、SQLite同一トランザクションでJournal置換・Checkpoint破棄・新epoch更新を行う。途中例外でのROLLBACK回帰テストを追加。
- 詳細は[JOURNAL_V2_ROLLBACK.md](JOURNAL_V2_ROLLBACK.md)。本APIは破損DB復旧・任意アーカイブ復元ではない。Controller未接続、全容量の復元・性能・障害注入やmacOS実機QA未完につき、**v1.0はNO-GO**のまま。

## P0証跡の再監査（CIで自動照合するインベントリ）

- [P0_RELEASE_EVIDENCE.json](P0_RELEASE_EVIDENCE.json) は148件を一意に列挙し、8つの横断ゲートを同じ形式で管理する。初期状態は `unverified`、資料から欠落が確認された項目だけ `blocked` とし、CI成功やコード存在をもって `passed` に自動昇格しない。
- `python3 scripts/release/audit_worktime_release.py` は受入ID重複・増減・証跡の形式を確認する。通常モードの成功は **台帳整合性のみ** の成功であり、リリースGOではない。
- Quality/Repository hygieneでOpenSpec CLI `@fission-ai/openspec@1.14.3`を厳密にバージョン固定し、`openspec validate initial-worktime-mvp --strict`を実行する。仕様エラーではQualityを失敗させる。CIの実行結果を確認するまではOpenSpecタスク1.3を未チェックにする。
- `python3 scripts/release/audit_worktime_release.py --require-complete --source-sha <40桁コミットSHA>` は全148件および8ゲートの `passed`、検証対象SHAと一致する証跡を要求する。将来これが成功しても、実際のOS操作や提供されたログの正しさは独立の承認者が確認する。
- 候補生成workflowは現行のまま維持する。RCは実機QAに必要なため、未完了のP0がある間も**候補生成そのものを禁止しない**。本番公開・GO判定は別ゲート。
- 特に既知のP0は容量枯渇、削除の対象範囲/中断、破損DBの保全・復旧。個々のテスト成功が横断P0の解消を意味しない。

## リリースを阻む条件と次の順序

1. OpenSpec strict validationの実行・結果記録。旧タスク記述は根拠付きで更新し、検証前にチェックしない。
2. P0全148件に試験ID・手動QA手順・対象層・状態を対応付け、未対応と仕様矛盾を特定する。特に全履歴の消去、中断時の旧世代復元拒否、休憩訂正、勤務中の過去日訂正を先に精査する。既存P0の削除/降格は別途利用者判断が必要。
3. 既存機能の不具合修正と障害注入。破損ファイル保全、書込み失敗、同時操作、SQLite整合性、通知障害、時計異常を確認。
4. 最新mainの全CI、手動release candidate workflow、ZIP展開検証とSHA256。
5. macOS実機の起動/通知/起床/複数画面/VoiceOver/更新/復元、負荷測定。結果を記録しP0全件の合格を確認。
6. 公開は別途明示操作。証明書なし配布の警告・配布元確認は省略しない。

実機、手動ワークフロー、CLIの実行結果がない限り、GOとしない。新規機能はv1.1以降の独立提案とする。

## 長期保存上限の暫定対策（BUG-01）

10,000イベント上限に対し残500件で警告し、残100件以下では新規勤務・再開の受付を停止する。既存勤務の退勤を一律に停止しない。100件は暫定的な運用余裕であり、観測・訂正・設定変更・16MiB payload・ディスク不足による枯渇を保証できない。履歴の自動削除は禁止。上限到達済みのactive勤務を安全に終了できる移行手順と、監査を保持したjournal圧縮/保存形式の移行を引き続きP0とする。境界値の回帰試験を追加。残1件および完全枯渇時のStore挙動を追加検証する。[容量枯渇時の保全・移行設計](JOURNAL_CAPACITY_RECOVERY.md)を参照。最新CIは未確認、根本対策は未実装。
