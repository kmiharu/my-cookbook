# 同じデータでバッチの時間・メモリ・転送量を測る

`spring-batch-examples/` で実行します。使い捨てのローカル環境を用意し、最初にアプリケーションイメージをビルドします。

```bash
./scripts/setup-local.sh
docker compose --profile batch build batch
```

## 100万行の両宛先出力と取込を測る

```bash
BATCH_BENCH_DB=cookbook_bench_1m \
BATCH_BENCH_SERVICES_READY=1 BATCH_BENCH_SKIP_BUILD=1 \
BATCH_BENCH_INCLUDE_IMPORT=1 BATCH_BENCH_IMPORT_WIDTH=1024 \
./batch-test-support/compare-local.sh 1000000 256 3 representative
```

Seedの乱数相当値は31、指定行幅は256です。NULLのメールアドレスとINACTIVEはそれぞれ10%です。出力は顧客ID順のCSVをgzip level 6で圧縮し、同じバイト列を2バケットに出します。fetchSizeとchunkSizeは1,000、multipartのpartSizeは8 MiBです。各出力の先頭試行はウォームアップです。取込は指定行幅1,024のCSVをストリーム生成し、一度だけ測ります。DB上で全ID、名前、NULLを含むメール、statusを照合します。

## 行幅を揃え、100万行と1000万行のメモリを比べる

```bash
for rows in 1000000 10000000; do
  BATCH_BENCH_DB="cookbook_bench_narrow_$rows" \
  BATCH_BENCH_SERVICES_READY=1 BATCH_BENCH_SKIP_BUILD=1 \
  BATCH_BENCH_DELETE_OBJECTS=1 \
  ./batch-test-support/compare-local.sh "$rows" 80 3 representative
done
```

指定行幅80はDBテーブル・インデックス・WAL用の容量を抑えるための設定です。実際の行幅は準備時の `avg(pg_column_size(c))` と照合時の展開後バイト数から確認します。`BATCH_BENCH_DELETE_OBJECTS=1` を指定した試験では、照合済みの出力オブジェクトを版ID指定で削除します。マニフェストと実行台帳は試験記録として残ります。

空きディスクが少ない検証ホストでは、同じPostgreSQLイメージで試験専用tmpfsを使えます。以下の設定で1000万行を1回測定できます。

```bash
source scripts/local-common.sh
export POSTGRES_USER="$(batch_env BATCH_DB_USER)"
export POSTGRES_PASSWORD="$(batch_env BATCH_DB_PASSWORD)"
bench_pg_image=$(docker inspect -f '{{.Image}}' "$(docker compose ps -q postgres)")
docker run -d --name cookbook-bench-pg-tmpfs \
  --network "${COMPOSE_PROJECT_NAME:-spring-batch-examples}_default" \
  --tmpfs /var/lib/postgresql/data:rw,size=4g,mode=0700 --shm-size 128m \
  -e POSTGRES_USER -e POSTGRES_PASSWORD -e POSTGRES_DB=postgres "$bench_pg_image"
docker exec cookbook-bench-pg-tmpfs pg_isready -U "$POSTGRES_USER" -d postgres

BATCH_BENCH_PG_CONTAINER=cookbook-bench-pg-tmpfs \
BATCH_BENCH_DB=cookbook_bench_narrow_10m \
BATCH_BENCH_SERVICES_READY=1 BATCH_BENCH_SKIP_BUILD=1 \
BATCH_BENCH_WARMUP=0 BATCH_BENCH_TRIAL_BUCKETS=1 \
./batch-test-support/compare-local.sh 10000000 80 1 representative
```

試行専用のローカルS3バケットを作り、照合後にキーと版IDを確認して削除します。DBのストレージが変わるので、通常ボリュームの試行と実行速度を直接比較する場合は条件差を記録します。tmpfsのデータは試験用PostgreSQLを停止すると失われます。

SeaweedFSの書き込み可能なボリュームが不足した場合は、同じバイナリの試験専用インスタンスで再試行できます。以下は既存の検証済みSeedを読み、新しいrunIdで測定する例です。

```bash
source scripts/local-common.sh
export AWS_ACCESS_KEY_ID="$(batch_env BATCH_S3_ACCESS_KEY)"
export AWS_SECRET_ACCESS_KEY="$(batch_env BATCH_S3_SECRET_KEY)"
bench_s3_image=$(docker inspect -f '{{.Image}}' "$(docker compose ps -q s3)")
docker run -d --name cookbook-bench-s3-tmpfs \
  --network "${COMPOSE_PROJECT_NAME:-spring-batch-examples}_default" \
  --tmpfs /data:rw,size=2g -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  "$bench_s3_image" mini -dir=/data -volume.max=32 -master.volumeSizeLimitMB=128
BATCH_BENCH_S3_CONTAINER=cookbook-bench-s3-tmpfs \
  ./batch-test-support/aws-benchmark.sh s3api list-buckets

BATCH_BENCH_PG_CONTAINER=cookbook-bench-pg-tmpfs \
BATCH_BENCH_S3_CONTAINER=cookbook-bench-s3-tmpfs \
BATCH_BENCH_DB=cookbook_bench_narrow_10m BATCH_BENCH_REUSE_SEED=1 \
BATCH_BENCH_SERVICES_READY=1 BATCH_BENCH_SKIP_BUILD=1 \
BATCH_BENCH_WARMUP=0 BATCH_BENCH_TRIAL_BUCKETS=1 \
./batch-test-support/compare-local.sh 10000000 80 1 representative
```

`BATCH_BENCH_REUSE_SEED=1` は完了したSeedの行数・行幅・seed値と、顧客ID範囲を照合します。試験専用SeaweedFSを指定した場合も、マルチパート、条件付き確定、格納バイトの検証にはS3 APIを使います。照合済みオブジェクトの版はS3 APIで削除し、試験専用バケットはSeaweedFSコンテナの停止・削除で回収します。

## fetchSize・gzip・転送Worker・パーティション・Chunkを比較する

```bash
BATCH_BENCH_DB=cookbook_bench_compare \
BATCH_BENCH_SERVICES_READY=1 BATCH_BENCH_SKIP_BUILD=1 \
./batch-test-support/compare-local.sh 100000 1024 3 fetch,gzip,multipart,partition,chunk
```

| 比較する条件 | Job | 変える設定 |
| --- | --- | --- |
| 顧客Cursorの取得単位 | FetchSizeBenchmark | fetchSize 100 / 1,000 / 10,000 |
| 顧客CSVのgzip圧縮レベル | GzipBenchmark | level 1 / 6 / 9 |
| 固定ワークからのマルチパート転送Worker数 | ParallelMultipartUpload | Worker 1 / 4、共有バッファ6、圧縮なし |
| 固定ワークのキー範囲とWorker数 | PartitionBenchmark | 1 / 2 / 4 / 8 |
| 入力ワークへのChunk件数 | ChunkSizeBenchmark | 100 / 1,000 / 2,000 |

転送Workerの効果を比べる際は格納バイト数からパート数を確認します。キー範囲分割ではパーティション別のgzipを読み、連続したID、件数、双方の格納バイト数とSHA-256を照合します。Chunkでは試行ごとに専用ID範囲の取込結果を消し、同一バイト列を別の入力キーとして登録します。`*.steps.tsv` のステージング・検証・業務反映を個別に比較します。

Dockerの一時レイヤーに十分な空きがない場合は、同じ実行JARをホストJVMで測れます。サービスはComposeで動作し、JVMのRSS/CPUはホストのプロセスを観測します。

```bash
BATCH_BENCH_DB=cookbook_bench_compare_host \
BATCH_BENCH_SERVICES_READY=1 \
BATCH_BENCH_HOST_JAR="$PWD/batch-examples/build/libs/batch-examples.jar" \
./batch-test-support/compare-local.sh 20000 1024 3 fetch,gzip,multipart,partition,chunk
```

## 4 KiB幅のCSVを10万行で測る

```bash
BATCH_BENCH_DB=cookbook_bench_wide_100k \
BATCH_BENCH_SERVICES_READY=1 BATCH_BENCH_WARMUP=0 \
BATCH_BENCH_HOST_JAR="$PWD/batch-examples/build/libs/batch-examples.jar" \
./batch-test-support/compare-local.sh 100000 4096 1 representative
```

## 試行別のメモリ・CPU・GCと結果を照合する

生ログは `bench-results/raw/<試行ID>/` に書きます。第5引数で保存先を変更できます。Javaは `-Xmx512m`、Composeのメモリ指定は4 GiBです。cgroupの実効上限がCompose指定と一致する場合に、バッチコンテナのメモリピークを集計します。サンプルの環境では上位cgroupのCPU割当も構成に影響するため、`environment.log` に記録します。

- `trials.tsv` はウォームアップ、結果検証、失敗を含む試行一覧です。
- `*.state.json` と `*.runtime.json` は開始・終了、終了コード、イメージIDまたはJARのSHA-256、資源設定を記録します。
- `*.samples.tsv` はJavaプロセスのRSS・高水位、CPU tickとcgroupの観測値です。JVMプロセス終了前の最後の標本までを記録します。
- `*.services.jsonl` はDB、S3、DynamoDB Localの資源標本です。`*.database-*.json*` はPostgreSQLの接続、ロック待ち、トランザクション長、コミットやI/Oカウンタです。
- `*.log` と `*.steps.tsv` はJVMのGC情報、JobとStepの時間、読込・書込・コミット件数です。並列Stepの時間は重なるため、個別時間を合算して全体時間を求めません。
- `*.verified.json` は検証で観測したオブジェクトの行数、格納・展開バイト数、SHA-256です。圧縮率は格納バイト数を展開後バイト数で割ります。
- `summary.json` は試行ごとの測定値と成功した測定試行の中央値・最小値・最大値です。行/秒とMiB/秒の分母はコンテナまたはホストJVMの稼働時間です。JVM heapはGC直前の最大観測値です。

SQLと索引の比較は `SqlOptimization` と `IndexOptimization` のJSON実行計画を照合します。JDBC反映は `BatchInsertBenchmark` で `executeUpdate` の逐次投入、`executeBatch` の一括投入、`reWriteBatchedInserts` を有効にした一括投入を比較します。COPY出力は `WorkTableExport` と `CopyExport` の同じデータ・ファイル仕様を比較します。COPY取込は `ChunkSizeBenchmark` と `CopyImport` の全体時間を比較し、COPYステージの時間も分けて記録します。DynamoDBは `DynamoDbBenchmark` で読取条件、page/batch/Worker数を変え、返却件数・走査件数・API呼出しを確認します。

測定後、不要になった自分の試験専用DBだけを削除できます。

```bash
docker compose exec -T postgres sh -ec \
  'exec dropdb -U "$POSTGRES_USER" "$1"' sh cookbook_bench_compare
```

## SQL・索引・JDBC・COPYの基本経路を比較する

```bash
./batch-test-support/compare-database-local.sh 6000 256 3
```

専用のPostgreSQL DBを作り、SQLと索引の実行計画、JDBCの逐次・バッチ・書換え、CursorとCOPY出力、ChunkとCOPY取込を1回のウォームアップと3回の測定で比較します。取込試行の前に専用の取込ID範囲を初期化し、固定のgzipデータを試行別のS3キーへコピーします。出力は2宛先のSHA-256と全IDを照合し、Cursor／COPYの展開後バイト列も比較します。取込は最終DB上で全対象行とNULL／空文字の区別を照合します。

詳細な計画は `*.plans.json`、JDBC投入時間はJobログ、COPY／Chunkの処理時間は `*.steps.tsv` に記録します。次のコマンドでSQLの実行時間、JDBC投入時間、Step時間の中央値と範囲を集計します。

```bash
./batch-test-support/summarize-database.py bench-results/raw/試行ディレクトリ
```

COPY取込のStep時間には事前検証とS3の再読込が含まれます。パーサーや `COPY FROM STDIN` 部分を計測して比較する場合は、Step内の所要時間を個別に採取します。システムの資源を共有する環境では、プロセス・DBの小さな試行のばらつきも確認します。

[2026-11-27に実行した6,000行の比較結果](../bench-results/database-6000.md)

[100万・1000万行の実測](../bench-results/local-2026-11-27.md) [2万行の比較測定](../bench-results/comparisons-2026-11-27.md)
