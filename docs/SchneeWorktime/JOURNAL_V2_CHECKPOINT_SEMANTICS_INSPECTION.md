# Journal v2候補Checkpointの意味的検証

## 原因
候補の`source_checkpoint`にはUUID文字列・Epoch・Revision・時刻の形式検証があるが、Checkpointの勤務IDが実際の勤務中IDか、観測時刻が出勤前でないかというDomain検証がなかった。候補内部に形式が正しい偽マーカーが混入した場合、単体のREADONLY検査だけでは拒否できない可能性があった。

## 変更
`JournalStagingInspection`の検査中に`JournalCheckpointAnchor.validate(source:now:)`を呼び出し、recordedの場合は旧JournalをCheckpoint時刻で再生して、その時点の`catalog.activeID`が`dayID`に一致することを要求する。`unbound`と`absent`は従来どおり処理する。正常な保全元に対して書込みを追加しない。候補の形式が正しくても別ID・出勤前の時刻に改竄された場合は拒否する。

## 限界
過去のイベントからCheckpointを「正しい観測結果」と認定する処理ではない。Checkpointは実勤務を確定せず、本番DBのCAS切替・世代フェンス・排他ロック・障害復旧の代替にならない。オフライン候補限定。v1.0 NO-GO。
