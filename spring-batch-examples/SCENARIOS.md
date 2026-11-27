# 顧客データを出力・取込・更新する49のシナリオ

## ローカルサービスを起動してサンプルを実行する

`spring-batch-examples/` で実行します。表のコマンドはBash関数 `b` と `i` を使います。一般業務の更新、削除、全件同期には検証専用のComposeプロジェクトを使用してください。各行は、記載した初期状態と新しい実行IDで試します。

```bash
export COMPOSE_PROJECT_NAME=cookbook-catalog
./scripts/setup-local.sh
source ./scripts/local-common.sh
build_local_image
run="catalog-$(date -u +%Y%m%dT%H%M%S)-$$"
input=$(batch_env BATCH_INPUT_BUCKET)
internal=$(batch_env BATCH_INTERNAL_BUCKET)
partner=$(batch_env BATCH_PARTNER_BUCKET)

b() {
    local job=$1 suffix=$2
    shift 2
    local_batch "job=$job" "runId=$run-$suffix" "$@"
}

# Upload named files to the input bucket and calculate hashes of the S3 bytes.
put() {
    local name=$1
    local_aws s3 cp - "s3://$input/$run/$name" --only-show-errors
}
hash() {
    local_aws s3 cp "s3://$input/$run/$1" - --only-show-errors | sha256sum | cut -d ' ' -f1
}
i() {
    local job=$1 suffix=$2 name=$3 rows=$4
    shift 4
    b "$job" "$suffix" "input.key=$run/$name" "input.sha256=$(hash "$name")" "input.rows=$rows" "$@"
}

b Migrate migrate
b Seed seed rows=8 seed=31 rowWidth=256
local_psql <<'SQL'
INSERT INTO membership(customer_id,member_id,tier) VALUES (1,101,'GOLD'),(1,102,'SILVER')
ON CONFLICT DO NOTHING;
SQL

printf '%s\n' 'id,name,email,status' '5001,追加顧客,,ACTIVE' | put one.csv
printf '%s\n' 'id,name,email,status' '1,既存の更新,new@example.invalid,INACTIVE' '5002,新規,,ACTIVE' | put upsert.csv
printf '%s\n' 'id,name,email,status' '5003,正常,,ACTIVE' 'bad,型不正,,ACTIVE' '5004,業務不正,,UNKNOWN' | put invalid.csv
printf '%s\n' 'id,name,email,status' '5005,一行目,,ACTIVE' '5006,二行目,,ACTIVE' | gzip -n | put pair-a.csv.gz
printf '%s\n' 'id,name,email,status' '5007,三行目,,ACTIVE' | gzip -n | put pair-b.csv.gz
printf '%s\n' 'id,version' '1,0' | put delete.csv
```

同じ入力版を顧客書込みの別のJobへ適用すると、二重適用防止が働きます。`upsert.csv`、`invalid.csv`、`pair-a.csv.gz` を別のシナリオで再利用する場合は、別キーにアップロードします。直接INSERTなどを試す場合は対象IDを変えるか、専用データベースで初期状態から始めます。`sql.fromDate` は含み、`sql.toDate` は含みません。Seedの顧客はUTCの2026-01-01に固定されます。

## 成果物と同じrunの再開を確認する

CSVのキーは `Job名/runId/成果物名.csv` です。TSVとgzipは拡張子に反映されます。出力Jobの `manifest.json` には、対象オブジェクトと宛先ごとの行数、サイズ、格納バイト列のSHA-256、取得できたversionIdを記録します。2宛先の場合は両方をGETしてハッシュを比較します。

```bash
key="WorkTableExport/$run-02/customers.csv.gz"
for bucket in "$internal" "$partner"; do
    local_aws s3 cp "s3://$bucket/$key" - --only-show-errors | sha256sum
done
local_aws s3 cp "s3://$internal/WorkTableExport/$run-02/manifest.json" - --only-show-errors | jq .
local_psql -v run_id="$run-02" <<'SQL'
SELECT artifact_id,destination,state,row_count,size_bytes,sha256,version_id
FROM batch_artifact WHERE run_id=:'run_id' ORDER BY artifact_id,destination;
SQL
```

通常の再開は前回のJob、runId、処理引数をそのまま使います。固定入力の履歴は `batch_input`、ファイル検証完了は `batch_input_check`、論理レコードの位置はStepのExecutionContextを確認します。入力版・設定が変わる場合は、修正した入力と新しいrunIdを使います。強制停止時にACTIVEが残った場合は、旧コンテナの停止とDBのowner・JobExecution IDを確認してから `recover.owner=… recover.executionId=…` を追加します。顧客テーブルを直接読む01・34・40では、部分出力から同じrunを再生成できる固定値がない場合、新しいrunで一式を発行します。

表の「標準」「イメージ」「業務」「Dynamo」「停止」「S3復旧」「Chunk復旧」「負荷」「比較」「DB比較」は次の検証入口です。各スクリプトは独立したフィクスチャと実行IDを使います。標準スクリプトは専用の空のプロジェクトで実行し、実行済みの固定IDを使い回さないようにします。実施結果はリポジトリの検証記録で確認してください。

| 実サービスで確認できること | コマンド |
| --- | --- |
| 顧客出力・取込・運用・性能Jobの27シナリオを少量データで照合する（標準） | `./scripts/verify-standard-scenarios.sh` |
| 最終イメージで2宛先出力、取込、引数拒否を検証する（イメージ） | `./scripts/verify-local.sh` |
| 別のPostgreSQL DBとS3で業務14シナリオを検証する（業務） | `./scripts/operations-scenarios.sh` |
| DynamoDB Local、PostgreSQL、S3で42〜49を検証する（Dynamo） | `./scripts/dynamodb-scenarios.sh` |
| 到着待ちのSIGTERMと同じrunでの再開を確認する（停止） | `./scripts/verify-stop-local.sh` |
| Complete後に停止し、同じS3 versionIdを認識して再開する（S3復旧） | `./scripts/verify-restart-s3.sh` |
| gzipのChunk確定後のSIGKILL・JVMヒープOOMとスキップの回復を確認する（Chunk復旧） | `./scripts/verify-chunk-recovery.sh` |
| 代表出力と100万行取込をストリーミングで照合する（負荷） | `COMPOSE_PROJECT_NAME=cookbook-bench-base ./scripts/benchmark-local.sh 1000000 256 3` |
| fetch・gzip・multipart・partition・chunkを比較する（比較） | `BATCH_BENCH_DB=cookbook_bench_compare ./batch-test-support/compare-local.sh 100000 1024 3` |
| SQL・索引・JDBC・COPYを同一データで比較する（DB比較） | `./batch-test-support/compare-database-local.sh 6000 256 3` |
| DynamoDBの固定世代を100万件で計測する | `./scripts/dynamodb-benchmark.sh 1000000` |


TestcontainersでS3、PostgreSQL、DynamoDBを使う試験と、SDK境界に故障を入れる単体試験はクラス単位でも実行できます。

```bash
./gradlew :batch-storage:test --tests '*LocalS3MultipartTest' --tests '*MultipartExporterTest'
./gradlew :batch-examples:test --tests '*OperationsRepositoryIntegrationTest'
./gradlew :batch-dynamodb:test --tests '*DynamoLocalTest' --tests '*DynamoRepositoryTest'
./gradlew :batch-file:test --tests '*DelimitedFilesTest'
```

## 顧客を抽出・登録・修正・削除する

| 何ができるか | No. | 準備と実行コマンド | 確認する結果 | 障害・再開と検証 |
| --- | --- | --- | --- | --- |
| 顧客を1〜2宛先のCSVに出力する | 01 | Seedの8件。 `b CustomerExport 01 destinations=both output.compression=gzip`。片側は `destinations=internal` または `partner` で別runを起動する。 | `customers.csv.gz` にID順で8件。両宛先のSHA-256が一致する。 | 直接SELECTで前回結果を復元できない場合は新規run。標準、負荷、`LocalS3MultipartTest`。 |
| 永続ワークに値を固定してから出力する | 02 | Seedの8件。 `b WorkTableExport 02 destinations=both output.compression=gzip` | `batch_work_status` がREADY。 `batch_customer_export` に固定値、両宛先に同じハッシュの `customers.csv.gz`。 | Complete直後に停止し、成功済みversionIdを保ったまま再開する。標準、イメージ、S3復旧。 |
| 顧客一覧と会員付き一覧を同じ時点で作る | 03 | 顧客8件、ID 1の会員2件。 `b MultiFileExport 03` | `customers.csv` 8件、`customer-members.csv` 9件。会員なしの顧客も1件ずつ出力。 | 片方の出力に失敗したら固定ワークから再開。manifestの2成果物と会員ID 101・102を照合する。標準。 |
| 顧客を直接INSERTし、Chunkの部分コミットを確認する | 04 | 新規IDの `one.csv`。 `i CustomerImport 04 one.csv 1 chunkSize=1` | `customer.id=5001` と入力適用台帳。 | `AFTER_CHUNK_COMMIT` で停止した場合は確定済みの顧客行が残る。履歴と件数を確認し同じrunを再開する。標準。Chunk復旧はワークへのChunk確定後の停止を検証する。 |
| 固定入力から顧客のINSERTとUPDATEを行う | 05 | ID 1と新規ID 5002を含む `upsert.csv`。 `i CustomerUpsert 05 upsert.csv 2` | 業務反映はEOF・SHA-256・件数確認後。既存顧客の名前・状態が変わり、ID 5002が増える。 | 失敗中のワークと入力版を確認する。同じ入力版の別run適用を拒否。標準、イメージ、負荷。 |
| 版が一致する顧客だけ削除する | 06 | ID 1の初期version 0と `delete.csv`。 `i CustomerDelete 06 delete.csv 1 expectedRows=1` | versionが一致する1件が消える。 | versionを先に変えると件数照合で失敗。業務では別のID 6で確認する。 |
| 型不正と業務不正を分離する | 07 | 正常1件、不正2件の `invalid.csv`。 `i ValidatedImport 07 invalid.csv 3 skipLimit=2` | 顧客はID 5003のみ追加。 `batch_input_error` と `errors.csv` に論理位置が2件。 | `skipLimit=1` の別runは反映前に失敗。CSVの閉じ引用符欠落はファイル全体エラー。`DelimitedFilesTest` も参照。標準。 |
| 複数入力を順番に取り込む | 08 | gzipの2件＋1件。 `b MultiFileImport 08 "input.keys=$run/pair-a.csv.gz,$run/pair-b.csv.gz" "input.sha256=$(hash pair-a.csv.gz),$(hash pair-b.csv.gz)" input.rows=2,1 input.compression=gzip` | `batch_input` と `batch_input_check` の `file_index=0,1` を確認し、3件を反映。 | 2番目のファイルを処理中に停止し、1番目の入力順・版と検証記録を保持して再開する。標準。 |
| 顧客の名前とメールを正規化して出力する | 09 | `local_psql -c "INSERT INTO customer(id,name,email,status) VALUES (9,' Name ',' SAMPLE@EXAMPLE.INVALID ','ACTIVE')"`。 `b DataTransform 09 idFrom=9 idTo=9 expectedRows=1` | `batch_operation_work` と `transformed.csv` に正規化済みの値。 | 出力失敗なら固定値から再生成してハッシュ照合。業務。 |
| 日次・月次の件数を置き換えて再集計する | 10 | 2026-01のSeed顧客。 `b Aggregation 10d period=day sql.fromDate=2026-01-01 sql.toDate=2026-02-01`。月次は `b Aggregation 10m period=month sql.fromDate=2026-01-01 sql.toDate=2026-02-01`。 | `batch_customer_totals` の対象日・月が8件。新しいrunで同じ期間を再集計しても二重加算しない。 | 月の途中の境界は拒否。業務。 |
| 事前確認した状態から条件付きUPDATEする | 11 | ID 1がACTIVE・version 0。 `b StatusUpdate 11 idFrom=1 idTo=1 targetStatus=INACTIVE expectedRows=1` | ID 1がINACTIVEでversion 1。 | 固定ワーク後に旧値・versionが変わると更新と件数確認が失敗。業務。 |
| 1回の一括SQLとChunk更新を比較する | 12 | ACTIVEの同じ範囲で試行間に初期状態を復元。 `b BulkUpdate 12s idFrom=1 idTo=8 targetStatus=INACTIVE expectedRows=8 mode=single` と `b BulkUpdate 12c idFrom=1 idTo=8 targetStatus=INACTIVE expectedRows=8 mode=chunk chunkSize=2`。 | 8件の状態とversionを更新。 | Chunkでは先行コミットが残るため同じrunを再開。業務。 |
| 顧客を取り込み、反映した行を送信する | 13 | 更新1件＋新規1件の入力。 `i ImportAndExport 13 upsert.csv 2 destinations=both` | `customer` に反映された2件を固定し、`customers.csv` とmanifestを両宛先へ出す。 | 出力の失敗時は業務反映を繰り返さず、固定ワークと成果物台帳を使う。標準。 |
| 入力とDBの新規・変更・欠落を突合する | 14 | 既存ID 1の変更、新規ID 5002、DBにのみあるID 2以降。 `i DataReconciliation 14 upsert.csv 2` | `reconciliation.csv` とワークに `NEW`、`CHANGED`、`MISSING`。 | 入力欠落・SHA不一致で失敗。業務では出力SHAと対象区分を検証する。 |
| 別のPostgreSQLへ顧客を移行する | 15 | Composeの `postgres-target` を起動し `b Migrate migrate` でスキーマを用意。 `b DataMigration 15 idFrom=1 idTo=1 expectedRows=1 chunkSize=1` | ターゲットの顧客1件と `batch_migration_progress` 1件を同一ターゲットDBで確定。 | ターゲット確定後にソース側停止が起きても、進捗を参照して再送する。業務。 |
| パッチをプレビューし、適用後に状態だけを戻す | 16 | ID 1がACTIVE・version 0。 `b DataPatch 16p "patchId=$run-patch" "planId=$run-plan" idFrom=1 idTo=1 targetStatus=INACTIVE expectedRows=1`。次に `b DataPatchApply 16a "patchId=$run-patch" "planId=$run-plan" expectedRows=1`、`b DataPatchRestore 16r "patchId=$run-patch" "planId=$run-plan" expectedRows=1`。 | `patch-preview.csv`、`patch-backup.csv`、`patch-diff.csv`、`patch-restore.csv`。DBはpreviewで不変、apply後version 1、restore後version 2。 | 別途 `mode=chunk chunkSize=1` を比較。二重適用、件数不一致、旧値／版競合で停止。業務、`OperationsRepositoryIntegrationTest`。 |
| 欠損メールを補完し、必要な場合に再計算する | 17 | `local_psql -c 'UPDATE customer SET email=NULL WHERE id=1'`。 `b DataBackfill 17 idFrom=1 idTo=1 expectedRows=1` | ID 1のメールは `customer-1@example.invalid`。 `recalculate=true` は既存の異なる値も対象。 | 競合した版は上書きしない。業務。 |
| S3へ退避した顧客の一致する版を削除する | 18 | 退避対象ID 1を用意。 `b DataArchive 18 idFrom=1 idTo=1 expectedRows=1` | `archive.csv` の確定確認後、元DBのID 1が消える。 | S3失敗または顧客の版が変わった場合は削除できない。業務。 |
| 保持期限超過の終了済みワークを整理する | 19 | 完了runとACTIVEのワークを90日前に設定した検証DB。 `b DataCleanup 19 retainDays=30` | 完了runの古いワークを削除し、実行中や再開待ちのワークを保持。 | 業務が完了・ACTIVEの両方を作り、対象runを照合する。 |

## 並列処理・再試行・ファイル連携を実行する

| 何ができるか | No. | 準備と実行コマンド | 確認する結果 | 障害・再開と検証 |
| --- | --- | --- | --- | --- |
| 事前確認からプレビュー／反映へ分ける | 20 | ACTIVEのID 1。 `b ConditionalFlow 20p branch=preview idFrom=1 idTo=1 targetStatus=INACTIVE expectedRows=1`。別runの `b ConditionalFlow 20a branch=apply idFrom=1 idTo=1 targetStatus=INACTIVE expectedRows=1`。 | どちらも `conditional.csv`。applyのみ状態を更新する。 | DB反映後のS3失敗では固定値を再送。業務。 |
| 顧客一覧と会員一覧を並列Stepで出力する | 21 | 03のデータ。 `b ParallelStep 21 totalBuffers=4` | 独立Stepの実行時間、`customers.csv` と `customer-members.csv`、共通manifest。 | 片方に失敗を入れ、成功したStep・オブジェクトの再利用を確認。`MultipartExporterTest` はバッファ制御も検証する。標準。 |
| ID範囲を分割して欠落・重複なしで出力する | 22 | Seedの8件。 `b Partitioned 22 partitions=4` | 独立した範囲オブジェクトとmanifest。全成果物のID合計8件で重複なし。 | 失敗範囲は同じワークから再出力する。`batch-test-support/verify-export.py` で全パートを照合する。標準。 |
| 一時的なPostgreSQL障害の後で再試行する | 23 | Seedの顧客。 `"${compose[@]}" --profile batch run --rm -T --no-deps -e SPRING_PROFILES_ACTIVE=local,fault-test -e BATCH_FAULT_PHASE=RETRY_SNAPSHOT batch job=Retry "runId=$run-23"` | 1回の一時障害ログ後に `customers.csv` とmanifestを出す。 | 一時障害だけを規定回数まで再試行する。固定ワークと成果物件数で確認。標準。 |
| 許容不正を除外して重複なくレポートする | 24 | 07と同等の別キー。 `i SkipRecord 24 invalid.csv 3 skipLimit=2 chunkSize=1` | `batch_input_error` と `errors.csv` に2件、顧客追加は1件。 | チェックポイントはスキップも含む。Chunk確定後に停止し、論理位置の重複がないことを確認する。標準、Chunk復旧。 |
| 中断したgzip取込を同じ論理位置から再開する | 25 | gzipの2件。 `i Restartable 25 pair-a.csv.gz 2 input.compression=gzip chunkSize=1` | 同じJobInstanceで新しいJobExecutionが作られ、ID 5005・5006の2件だけを反映。 | `fault-test` で `AFTER_CHUNK_COMMIT` を指定し、再開時はhookを外す。S3版とExecutionContextを照合する。標準、Chunk復旧。 |
| 到着・準備完了を待ち、期限を超えたら失敗する | 26 | 入力本体とオプションの準備完了キー。 `b FileArrivalCheck 26 "input.key=$run/one.csv" "input.sha256=$(hash one.csv)" "input.readyKey=$run/ready" arrivalTimeoutSeconds=15`。バックグラウンドまたは別シェルで待機中に `printf ready \| put ready`。 | `batch_input` の入力版を固定して完了。業務DBは変更なし。 | マーカーを置かずに期限超過、またはSIGTERM後に同じrunで再開。停止。標準。 |
| 完全性確認後にマスターを同期する | 27 | 完全入力にあるID 1・5002。 `i MasterSync 27 upsert.csv 2 expectedRows=2 deleteMissing=true` | 検証成功後に対象の2件を反映し、完全入力にない顧客を整理。既定では削除しない。 | 不足・SHA不一致の入力で削除が起きないことを確認。業務。 |
| 固定した上限までの差分を重複期間付きで出す | 28 | UTC 2026-01-01のSeed。 `b IncrementalExport 28 "watermarkId=$run-inc" sql.fromDate=2026-01-01 sql.toDate=2026-01-02 overlapSeconds=900` | `incremental.csv` とmanifestが確定し、 `batch_watermark.next_lower` が上限へ進む。 | 出力失敗時にウォーターマークを進めない。受信側は顧客キーとversionで冪等処理。業務。 |
| 世代を分けて顧客全件を出力する | 29 | Seedの8件。 `b FullExport 29 output.format=tsv destinations=both` | runId単位の `customers.tsv` とmanifest。前世代のキーを保持。 | 同じrunは固定ワークを使う。別世代を起動し、両世代のHEADと件数を確認する。標準。 |
| S3オブジェクトをバイト列のまま転送する | 30 | 1個の保存済み入力。 `b FileTransfer 30 "input.key=$run/one.csv" "input.sha256=$(hash one.csv)" destinations=both` | `transferred.bin` とmanifest。入力と両出力のSHA-256が一致。 | 片側の送信失敗時に固定入力版から再開。同じ入力版で `transferMode=copy` を別runに設定してSHA-256を比較する。標準。 |
| SHA-256・gzip終端・件数を検証する | 31 | gzipの2論理レコード。 `i ChecksumValidation 31 pair-a.csv.gz 2 input.compression=gzip` | `batch_input_check` に2件と実測SHA-256、ワークがREADY。 | 指定SHA・期待件数・gzip終端を別々に壊して非0終了と業務未反映を確認。ETagは同一入力版の判定に使う。標準。 |

S3の `transferMode=copy` を使う場合は、宛先のSDK認証ロールに入力versionの読取と書込みの両方が必要です。先に固定した入力をGETしてSHA-256を照合し、各宛先へ版を指定してCopyObjectを発行します。5 GBを超える格納データはこの経路の対象外です。バッチでストリーミング転送した成果物とSHA-256を比較できます。

```bash
b FileTransfer 30copy "input.key=$run/one.csv" "input.sha256=$(hash one.csv)" transferMode=copy
local_aws s3 cp "s3://$internal/FileTransfer/$run-30copy/transferred.bin" - --only-show-errors | sha256sum
```

## SQL・索引・JDBC・S3転送を比較する

測定するたびに独立したrunIdを使います。[測定の手順](batch-test-support/README.md)に従い、準備・ウォームアップ・測定・照合を分けます。比較スクリプトは`trials.tsv` と `summary.json` を記録します。単発コマンドは動作確認向けで、性能の結論には測定記録を使います。

| 何ができるか | No. | 準備と実行コマンド | 確認する結果 | 障害・再開と検証 |
| --- | --- | --- | --- | --- |
| 関数で絞るSQLと時刻範囲SQLを比較する | 32 | 2026-01-01に分布させたSeed。 `b SqlOptimization 32` | 前後の `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`。実測行数、索引、Sort、バッファを比較。 | SQL失敗なら非0。同じデータで計画の実測行数を確認。標準。 DB比較。 |
| 索引なしと複合索引の計画を比較する | 33 | 十分な行数と状態の偏りがあるSeed。 `b IndexOptimization 33` | 索引前後のJSON計画を同じ条件で比較し、行数一致を確認。 | DDLで準備した計測用テーブルの対象runだけを後処理する。失敗試行も計画と終了ログを残す。標準。 DB比較。 |
| JDBC fetchSizeを100／1,000／10,000で測る | 34 | 同じSeed、ソート、2宛先のgzip。 `b FetchSizeBenchmark 34 fetchSize=1000 destinations=both output.compression=gzip` | 同一格納バイト列のSHAと行数、時間、メモリ。 | 直接SELECTの出力失敗は新runで測り直す。比較の `fetch`。標準。 |
| JDBC逐次INSERT、バッチ、SQL書換えを比較する | 35 | 同じ行数と幅。 `b BatchInsertBenchmark 35s mode=sequential rows=10000 rowWidth=256`。別runで `mode=batch` と `mode=rewrite`。 | 各試行の件数・経過時間・backend PID。バッチは `executeBatch` を使う。 | 失敗試行を残して同じ初期条件へ戻す。計測用テーブルへの投入件数はJob内で照合する。標準。 DB比較。 |
| PostgreSQL COPY TO STDOUTでCSVを送信する | 36 | Seedを固定ワークに保存。 `b CopyExport 36 output.format=csv output.compression=gzip` | `customers.csv.gz` とmanifest。通常Cursorと同じ論理行を照合。 | COPY文・接続設定は固定。COPY非対応の文字コード／CRLFは引数段階で拒否。標準。 DB比較。 |
| PostgreSQL COPY FROM STDINで取り込む | 37 | UTF-8／LFの入力。 `i CopyImport 37 upsert.csv 2` | `batch_copy_stage` から型検証・業務反映。通常取込と対象DB行を比較。 | COPY失敗後は同じ入力版を先頭から再試行し、Chunk再開とは別の保証範囲で検証する。標準。 DB比較。 |
| multipartの送信Worker数を比較する | 38 | 8 MiBを超える格納データで比較。 `b ParallelMultipartUpload 38 destinations=both output.compression=gzip transferWorkers=4 totalBuffers=6` | Worker 1と4で同じ行数とSHA、メモリpeakと転送量を記録。 | 片側失敗・遅延時はバッファを保持しAbortと再開を確認。比較の `multipart`、`MultipartExporterTest`。標準。 |
| キー範囲をWorker 1／2／4／8で比較する | 39 | 同じSeedとCPU・メモリ割当。 `b PartitionBenchmark 39 partitions=4 destinations=both output.compression=gzip` | 全範囲の合計行数、欠落・重複、各宛先のハッシュ、処理時間と接続数。 | 失敗した範囲と成功済み成果物を照合。比較の `partition`。標準。 |
| gzipレベル1／6／9で時間と圧縮率を測る | 40 | 同じCursor、行順、2宛先。 `b GzipBenchmark 40 destinations=both output.compression=gzip output.gzipLevel=6` | レベルごとのCPU・時間・格納バイト数。解凍後の論理行は同じ。 | gzip終端なしの成果物を完了扱いしない。比較の `gzip`。標準。 |
| Chunk件数とコミット・メモリ・再開を比較する | 41 | 専用DBと同じ論理入力。 `i ChunkSizeBenchmark 41 pair-a.csv.gz 2 input.compression=gzip chunkSize=1000` | `batch_step_execution.commit_count`、DB反映、heap・RSS、再開時の読み飛ばし。 | 試行ごとに専用の顧客範囲と入力キーを初期化。比較の `chunk`。標準。 |

## DynamoDBを読み取り、条件付きで更新する

DynamoDB用の3件の入力は `pk,sk,version,status,balance,memo_state,memo` を持ちます。具体的なフィクスチャ、命令ごとの実行引数と検証は [dynamodb-scenarios.sh](scripts/dynamodb-scenarios.sh) がCI・ローカルで使用します。次の準備で44の新規登録も実行します。例の `part` は専用の固定入力世代、`first` はその中の1個のSKです。入力版を固定してから読み取りを始め、抽出中の同じ世代への書込みを避けます。Scan開始時点の全体スナップショットは保証の範囲外です。

```bash
part="$run-ddb"
first=6001
ddb_fixture() {
    printf 'pk,sk,version,status,balance,memo_state,memo\n%s,%s,0,ACTIVE,2.125,VALUE,"多行\n名前"\n%s,6002,0,ACTIVE,0,NULL,\n%s,6003,0,INACTIVE,0,VALUE,""\n' \
        "$1" "$first" "$1" "$1"
}
ddb_fixture "$part" | put dynamo.csv
ddb_fixture "generation:$part" | put generation.csv
printf 'pk,sk,version,delta\n%s,%s,0,1.25\n' "$part" "$first" | put add.csv
printf 'pk,sk,version,status,balance,memo_state,memo\n%s,%s,1,ACTIVE,3.375,ABSENT,\n' \
    "$part" "$first" | put dynamo-update.csv
printf 'pk,sk,version\n%s,6002,0\n' "$part" | put dynamo-delete.csv
i DynamoDbImport 44 dynamo.csv 3 "dynamo.partition=$part" dynamo.workers=2
```

| 何ができるか | No. | 準備と実行コマンド | 確認する結果 | 障害・再開と検証 |
| --- | --- | --- | --- | --- |
| パーティションキーまたはGSIでQueryして出力する | 42 | 3件の固定世代。 `b DynamoDbQueryExport 42 "dynamo.partition=$part" dynamo.pageLimit=1 dynamo.expectedItems=3 output.compression=gzip`。GSIでは `dynamo.gsi=true dynamo.status=ACTIVE dynamo.expectedItems=2`。 | `dynamo_work` と `customers.csv.gz`。GSIではACTIVE 2件。 | 空ページでもLastEvaluatedKeyがあれば続行する。Dynamo、`DynamoRepositoryTest`。 |
| 逐次Scan結果を固定ワークのキー順で出力する | 43 | 42と同じ3件。 `b DynamoDbScanExport 43 "dynamo.partition=$part" dynamo.pageLimit=1 dynamo.expectedItems=3 output.compression=gzip` | 通常Queryと同一列・キー順の `customers.csv.gz`。同じ入力世代でQuery・ScanのSHAが一致。 | ページの再読でキー重複を防ぐ。Dynamo。 |
| 条件付き新規登録と専用世代の全体置換を行う | 44 | 3件の入力。 `i DynamoDbImport 44 dynamo.csv 3 "dynamo.partition=$part" dynamo.workers=2`。置換は `i DynamoDbImport 44g generation.csv 3 "dynamo.partition=generation:$part" dynamo.writeMode=replace`。 | DynamoDBの3項目に小数・NULL・空文字、S3に `delivery.csv`。 | 重複キー・異なるpayloadを拒否。BatchWriteの未処理分だけ再送する。Dynamo、`DynamoRepositoryTest`。 |
| 版付き部分更新・加算を一度だけ反映する | 45 | version 0、balance 2.125の `$first`。 `i DynamoDbConditionalUpdate 45 add.csv 1 "dynamo.partition=$part" dynamo.operation=add`。次に `i DynamoDbConditionalUpdate 45u dynamo-update.csv 1 "dynamo.partition=$part"`。 | 加算後はbalance 3.375、version 1。部分更新後はversion 2。操作ID記録と `delivery.csv`。 | `AFTER_DYNAMO_WRITE` で成功応答後の障害を入れ、同じrunでversionとbalanceが変わらないことを確認。Dynamo。 |
| 期待versionに一致するキーだけ削除する | 46 | version 0のSK 6002。 `i DynamoDbDelete 46 dynamo-delete.csv 1 "dynamo.partition=$part"` | 対象の項目がなくなり、操作ID記録と `delivery.csv` を確認できる。 | 版競合では非0、削除成功済みの再送は記録で確認。Dynamo。 |
| 固定PostgreSQLデータをDynamoDBへ配送する | 47 | SeedのUTC 2026-01-01の範囲。 `b PostgreSqlToDynamoDb 47 "dynamo.partition=pg-$part" sql.fromDate=2026-01-01 sql.toDate=2026-01-02`。業務更新の配送は `dynamo.operation=outbox dynamo.status=INACTIVE` で別run。 | DynamoDBのPK/SK・version・状態が対応。outboxではPostgreSQL更新と記録が同時に確定し、配送後に `delivered`。 | DynamoDB成功の後で失敗しても操作IDとversionにより再送できる。Dynamo。 |
| DynamoDBからPostgreSQLへ固定値を反映する | 48 | 46後の2件。 `b DynamoDbToPostgreSql 48 "dynamo.partition=$part" dynamo.readMode=SCAN dynamo.expectedItems=2 dynamo.pageLimit=1` | `dynamo_work` を検証後、PostgreSQLの `customer` に2件を反映。削除済み6002は作らない。 | ページ再読・業務DB反映の再開を同じrunで確認。Dynamo。 |
| Query／Scan・ページ・バッチ・Worker数を比較する | 49 | 同じ固定世代の2件。 `b DynamoDbBenchmark 49 "dynamo.partition=$part" "dynamo.targetPartition=generation:$part-49" dynamo.readMode=QUERY dynamo.pageLimit=1 dynamo.batchSize=2 dynamo.workers=1 dynamo.expectedItems=2`。別世代へSCANも実行。 | API数、Count、ScannedCount、retry、未処理項目と `customers.csv`。測定は固定世代ごとに比較。 | Dynamo、`DynamoRepositoryTest`。Localではprovisioned throughputと並列Scanの本番特性を測定できない。 |
