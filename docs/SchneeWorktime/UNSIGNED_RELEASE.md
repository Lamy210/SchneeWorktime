# SchneeWorktime: Developer IDなしの配布

初期配布は **Developer ID証明書なし・Apple公証なし**。Apple Siliconで必要となる実行時コード署名との区別のため、バンドルには証明書不要のad-hoc署名を付与する。発行者の真正性やAppleによる安全性確認を保証するものではない。

## 候補の生成

- Actionsの「Worktime Release Candidate」をmainから手動実行し、X.Y.Zを指定する。自動公開・タグ作成・Apple秘密情報・書込権限は不要。
- テストとreleaseビルドを実施し、macOS 15以降・Runnerが生成した単一architecture（arm64またはx86_64）の.appをZIP化。Mac実機での起動は別ゲート。
- 生成物: SchneeWorktime-<version>-macos-<arch>-adhoc.zip、SHA256SUMS、candidate.json。ZIPの展開後コード署名・plist・実行ファイルのdigestを再検証。Actions artifactはrun ID/attemptに紐付き14日保持。
- 公開前にmainの対象SHAのCI完了、候補のsource SHA、バージョン、architecture、checksum、実機での起動/通知/保存/更新/復旧を確認。GitHub Releasesへの公開は別の明示操作で、タグを検証済みSHAに固定する。既存の署名付き汎用publisher契約は変更しない。署名付き配布やHomebrewを完了とみなさない。

## インストール時の注意

Appleによる公証がないためGatekeeperで警告・起動拒否が発生し得る。配布元とSHA256を独立に確認する。管理端末では管理ポリシーに従う。Gatekeeper全体を無効化したり、quarantineを一括除去したりしない。

信頼できる配布元かつ改ざんされていないと確認できる場合に限り、Apple公式の個別アプリに対する例外手順を参照する。
- https://support.apple.com/ja-jp/102445
- https://developer.apple.com/jp/developer-id/

公開候補は正式な会社勤怠記録ではない。初回試験は隔離アカウントを使用し、既存の記録がある場合はバックアップする。チェックサムは破損や一致の確認であり、発行者署名の代替ではない。
