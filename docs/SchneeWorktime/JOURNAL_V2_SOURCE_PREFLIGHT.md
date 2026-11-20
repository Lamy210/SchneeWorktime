# Journal v2 候補と現行保存版の読取専用事前照合

Journal v2移行候補は、単独の検証に成功しても現在の稼働DBに対応するとは限らない。
`CatalogRepository.inspectJournalV2Candidate(_:now:)` は次の順序で読取専用の事前照合を行う。

1. schema-1現行DBから完全なsnapshotを読込・Journal再生検証する。
2. 隔離候補DBを独立してREADONLYで再読込し、イベント行・旧payload・Catalogの整合を検証する。
3. 現行保存版と候補内に保持する元snapshotを **epoch・revision・payload全bytes** で比較し、Catalogも一致させる。
4. 事前検査中の現行DB変更を可能な範囲で検知するため、現行保存版をもう一度読込・照合する。

不一致・別DBの同一revision・事前検査の前に保存版が進んだ状態は拒否する。
この処理は採用APIではない。呼び出し終了後の競合を防ぐことはできず、移行確定時には
**現行DBと候補の原子的CAS、専用セッションロック、バックアップ、クラッシュ復旧、世代フェンス**
が別途必要。既存schema-1を変更したり候補を採用したりする動作は含まない。

回帰試験: 一致する保存版の正常照合、保存更新済み候補の拒否、同じrevisionの別DB拒否。
macOS実機・並列writer・電源断・実DB移行は未検証。v1.0リリースGO判定は行わない。
