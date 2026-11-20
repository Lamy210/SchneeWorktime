# Journal v2 分離SQLite候補の永続化

PR #84のイベント行codecに依存する試作。内部APIで検証済みschema-1 snapshotから新しい0700ディレクトリ・0600候補DBを作る。live DBへのパス指定・採用は提供しない。新世代と旧完全payload、イベント行を単一BEGIN IMMEDIATEで保存し、user_version=2とする。候補を再openしREADONLY/query_onlyで元draftの全bytes・sequence・epoch・revisionを照合し、Domain再生等価性を検証する。

SQLite LENGTH上限17MiBは旧16MiBと行メタデータのための暫定防御。イベント行の個別/総上限は#84と同じ。検証中は一致した行だけを使うため、不正な余剰行は拒否する。checkpoint・新規イベントの永続追加・CAS・採用・障害復旧は未実装。候補破損時に修復や自動削除は行わず、原本の保全を優先。実際のDBをこの経路で移行しない。

試験: 旧DBのbytes保持、別候補の再open照合、旧版のschema拒否、候補イベント欠落拒否、不正原本で候補を作らない。CI未確認。実ディスク枯渇・停電・並列writer・性能は今後。v1.0 NO-GO。

## 独立検査
候補生成時のメモリdraftなしでもREADONLYでメタデータと旧payload、連続行を取得する。旧schema-1の検証と全イベントの型値比較、全catalog再生比較を実施。取得前にrevisionと個別/総bytesを制限し、余剰行も拒否。元draftがある場合は引き続き完全bytesを比較する。候補内の整合性は真正性を証明しない。採用時は別に保全した原本および現在のlive epoch/revision/完全bytesとの外部照合が必須。まだ追加イベントを含む候補は対象外。空候補・正常候補・別の有効なイベントに変えた候補の検査試験を追加。CI未確認。
