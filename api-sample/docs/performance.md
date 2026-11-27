# 同じデータで実行方法と検索方式を比較する

## ローカルで測定する

`api-sample/` で次のコマンドを実行する。Linux、Docker Compose、Python 3.11 以降、C コンパイラ、zlib の開発用ヘッダーと基本的なビルドツールが必要。`scripts/tools.sh install nik` は Linux x86_64 向けに固定した Liberica NIK を取得する。`NIK_HOME` を指定する場合も同じ Java 21 系の実行環境を使用し、実際のバージョンを記録する。

```sh
make benchmark
make benchmark-native
```

`make benchmark` は DynamoDB の書き込みと検索、PostgreSQL の検索と同時負荷、Hybrid の同期を測る。`make benchmark-native` は Java 21 の通常配布物と Native Image をビルドする。Native のプロセスで3モードの CRUD を通してから、Aurora モードの同じ API とデータで JVM と Native を比較する。Hybrid の同期ワーカーは JVM を使う。`make native-smoke` ではビルドと CRUD だけを実行できる。`BENCH_NATIVE_QUICK=1` は GraalVM の `-Ob` と `--parallelism=4` を使う動作確認用。既定の最適化とは計測条件が変わるため、試行の結果を比較する場合は同じ設定を使う。

各コマンドは専用 Gradle ビルド先と Compose プロジェクト、ループバックのポートを使う。レポートと k6 の生集計、アプリログは `.local/benchmarks/<UTC時刻>-<PID>/` に残る。試行の終了時に専用コンテナとボリュームを片付ける。CloudWatch、AWS その他の外部サービスへ測定値を送信しない。

| 比較 | 測定方法 |
| --- | --- |
| JVM / Native | 同一ソースと NIK/JDK 21 で通常配布物と Native Image をそれぞれビルド。起動から TCP ポートが開くまでを測り、最初の `GET /products/{id}` の応答時間を記録。負荷直後の `VmRSS` と起動後の最大 `VmHWM` を取得 |
| 単件 / 一括 | DynamoDB Local の専用テーブルへ、同じデータ件数を個別 `PutItem` と `BatchWriteItem` で書き込む。書き込み完了までの時間と実効件数/秒を比較 |
| Query / Scan | 同じ10%の分類データを GSI の `Query` とページ付き `Scan` で取得。両方の件数と絞り込み前の評価件数を確認 |
| SQL インデックス | `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` で一覧の計画を保存。専用データベースでインデックスを削除して同じクエリを再測定 |
| OFFSET / キーセット | 対象分類の90%付近で同じ20行を取得。キーセット用の境界は測定前に用意し、2方式で一致することを確認 |
| 同時負荷 / PG プール | 2・8接続それぞれで1・8・32 VU。固定分類を `limit=20` で検索し、p50、p95、p99、スループット、エラー率を取得 |
| 同期と復旧 | HTTP 書き込み成功から Hybrid の一覧に現れるまでを50ms間隔の確認で測る。PostgreSQL 停止中の書き込みを失敗レコードとして確認し、`docker start` から一覧で確認できるまでを記録 |

通常は10,000件、各負荷のウォームアップ10秒と測定30秒、各3試行で実行する。短い動作確認では `BENCH_DATASET_SIZE=400 BENCH_WARMUP_SECONDS=1 BENCH_DURATION_SECONDS=2 BENCH_REPETITIONS=1` で上書きする。JVM と Native はともにヒープ初期値64 MiB、上限256 MiBで起動する。両者の計測ではリクエストごとのアクセスログを無効にする。ビルド時間は依存がキャッシュに入った状態で `--rerun-tasks` を付けた各タスクの実行時間を記録する。再現時は先に通常ビルドを1回実行して依存キャッシュを準備する。

## 結果を読む

実行環境は Linux 6.18.57 / x86_64 / glibc 2.41、Intel Xeon Platinum 8573C、cgroup 上限4 CPU・16 GiB。Java は Liberica NIK 23.1.13+1 / JDK 21.0.13.0.3+6、Docker Engine 29.9.2、Compose 2.40.3、DynamoDB Local 3.3.2、PostgreSQL 16.14、k6 2.4.0 を使用した。並行してローカルの結合検証を実施していたため、CPU と I/O の競合を含む短時間の確認値として扱う。

短時間の全測定コマンドは、次の条件で終了コード0を確認した。DynamoDB の結果件数、PostgreSQL の6負荷条件、SQL の20件のページ一致、Hybrid の反映と復旧が通った。全6負荷条件で HTTP エラー率は0%。この実行の同期反映は305.3 ms、PostgreSQL 再起動からの復旧は3,775.8 msだった。

```sh
BENCH_DATASET_SIZE=400 BENCH_WARMUP_SECONDS=1 BENCH_DURATION_SECONDS=2 \
  BENCH_REPETITIONS=1 make benchmark
```

### DynamoDB Local の実測

| データと接続経路 | 単件 PutItem | BatchWriteItem | GSI Query | Scan | 一致件数 / Scan 評価件数 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000件、ホストの公開ポート | 74.129秒 | 23.796秒 | 163.056 ms | 897.555 ms | 100 / 1,000 |
| 10,000件、同一 Docker ネットワーク名前空間 | 207.975秒 | 28.717秒 | 1,215.426 ms | 4,934.923 ms | 1,000 / 10,000 |

各行1回の実行。1,000件は短時間の `make benchmark` の DynamoDB 段階で実行した。10,000件は JVM が同一ネットワーク名前空間に入る追加確認で、エミュレーターは `-inMemory -sharedDb`、Temurin 21.0.13 の JVM を使用した。書き込みはそれぞれ同じデータを空の専用テーブルに登録した。10,000件では単件が約48.08件/秒、一括が約348.22件/秒だった。比較は各行の接続経路内に限定する。

```sh
make build
container="cookbook-bench-dynamo-$$"
docker run -d --rm --name "$container" \
  amazon/dynamodb-local:3.3.2@sha256:6ada631ec7aa5fc83446855eb17233e3dad184fec47477e8140c6c569cfe0c86 \
  -jar DynamoDBLocal.jar -inMemory -sharedDb
trap 'docker stop "$container" >/dev/null' EXIT
# エミュレーターの起動ログで待受を確認してから実行する。
docker run --rm --network "container:$container" \
  --mount "type=bind,src=$PWD/app/build/install/products-api/lib,dst=/deps,readonly" \
  -e APP_RUNTIME=local -e DATABASE_TYPE=dynamodb -e DYNAMODB_TABLE=products \
  -e DYNAMODB_ENDPOINT=http://127.0.0.1:8000 \
  eclipse-temurin:21.0.13_9-jre@sha256:ca73b4d3961703d6d7830a4361f49ef0478f8f28b39defc07bb72f4cc7f834f6 \
  java -cp '/deps/*' cookbook.api.db.DynamoAdmin benchmark 10000
```

### PostgreSQL 10,000件で検索方式を比較する

`run.py` の `seed_postgres` と `sql_compare` を使い、10,000件かつ対象分類1,000件で `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` を3回ずつ実行した。同じ測定は `BENCH_DATASET_SIZE=10000 BENCH_REPETITIONS=3 make benchmark` の SQL 段階でも再現できる。

| クエリ | 実行時間の中央値 | 実行時間の範囲 | 3回目の計画 |
| --- | ---: | ---: | --- |
| インデックスありの先頭ページ | 0.107 ms | 0.078–0.260 ms | `Index Only Scan` の出力20行、共有バッファヒット3 |
| インデックスなしの先頭ページ | 26.961 ms | 2.105–154.770 ms | `Seq Scan` で分類一致1,000行を出力し、`Sort` で上位20件を取得 |
| `OFFSET 900` | 1.610 ms | 0.429–6.656 ms | `Index Only Scan` の出力920行、共有バッファヒット12 |
| 同じ位置からのキーセット | 0.097 ms | 0.095–0.356 ms | `Index Only Scan` の出力20行、共有バッファヒット4 |

深い位置で取得した20件の ID は両方式で一致した。小さい試行数で実行時間にばらつきがあるため、検索方式の比較では実行計画の行数とバッファも確認する。 [PostgreSQL 16 の EXPLAIN](https://www.postgresql.org/docs/16/using-explain.html)

### PostgreSQL の接続数を変えて HTTP 負荷を測る

`BENCH_DATASET_SIZE=1000 BENCH_WARMUP_SECONDS=1 BENCH_DURATION_SECONDS=3 BENCH_REPETITIONS=1 make benchmark` の設定で実測した。初回の実行は JVM の初回 HTTP 応答待ちで停止した。応答の上限を20秒、ポートを待つ上限を60秒に変更し、同じデータと負荷条件で未完了のケースを再実行した。

| プール上限 | VU | p50 (ms) | p95 (ms) | p99 (ms) | リクエスト/秒 | HTTP エラー率 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 1 | 92.43 | 211.67 | 344.98 | 9.30 | 0% |
| 2 | 8 | 105.42 | 382.13 | 512.45 | 52.83 | 0% |
| 2 | 32 | 414.83 | 684.39 | 886.07 | 68.93 | 0% |
| 8 | 1 | 66.60 | 156.62 | 447.15 | 11.39 | 0% |
| 8 | 8 | 87.36 | 299.67 | 352.76 | 68.87 | 0% |
| 8 | 32 | 100.94 | 255.56 | 310.48 | 258.36 | 0% |

プール2と8のケースは別時刻に測定したため、バックグラウンドの負荷も測定差に含まれる。実運用のプール値を決める際は、決まったCPU・メモリ条件で試行回数と測定時間を増やす。

### Hybrid の反映と PostgreSQL 停止後の復旧を測る

登録1件のウォームアップ後、次の登録から一覧に見えるまでに408.4 msかかった。PostgreSQL を停止した状態でも HTTP 登録は成功し、ワーカーの失敗ファイルが作成された。`docker start` の呼び出しから、ワーカーの再試行後に一覧で確認できるまでに1,544.5 msかかった。各1回の測定。

最初の再起動確認では、Docker が自動採番した PostgreSQL の公開ポートが変わったため、再試行が元のポートに接続し続けた。ベンチマークの Hybrid 構成では起動時に選んだループバックのポートを固定し、同じ接続先で復旧を測り直した。

### 同じ DynamoDB Local データで JVM と Native Image を比較する

既定の最適化 `-O2` で Native Image をビルドした。比較では同じ1,000件を使い、同一の外部 Logback `PatternLayoutEncoder` 設定を両方に指定した。k6 は1 VU、ウォームアップ1秒、測定3秒を各1回行った。先頭ページには20件が含まれ、両方で HTTP エラーとページ検証エラーは0件だった。

| 指標 | JVM | Native Image (`-O2`) |
| --- | ---: | ---: |
| 起動から TCP ポートまで | 8,836.4 ms | 717.9 ms |
| 初回の単件 GET 応答 | 3,417.1 ms | 333.8 ms |
| 一覧 p50 / p95 / p99 | 112.20 / 174.37 / 218.81 ms | 27.66 / 53.29 / 97.14 ms |
| スループット | 7.70 req/s | 30.57 req/s |
| 負荷直後の RSS / 最大 RSS | 249.9 / 249.9 MiB | 144.8 / 144.8 MiB |
| ビルド実時間 (`installDist` / `nativeCompile`) | 116.44秒 | 1,178.27秒 |

Native コンパイラ単体は17分58秒で実行ファイルを生成し、出力は152.46 MB、コンパイラのピーク RSS は6.64 GBだった。初回の Native バイナリは DynamoDB の CRUD・競合・ページングを通過した。Aurora の起動時には MyBatis の Javassist が反射で読むクラスが見つからず、JSON ログエンコーダーの反射設定も不足していた。この比較は同じバイナリが動作した DynamoDB モードを使った追加確認で、通常の Native 比較コマンドの負荷対象は Aurora モード。

2回目のビルドでは、Aurora が MyBatis の SQL ロガーを反射で生成する段階まで進んだ。そこで JVM の Aurora CRUD テストを `native-image-agent` 付きで実行し、ロガーのコンストラクタ、動的 SQL、JDBC で使われた反射とプロキシの情報からサンプルのメタデータを追加した。

### 同じ PostgreSQL データで修正後の JVM と Native Image を比較する

次のコマンドは終了コード0だった。修正後の Native バイナリで `dynamodb`、`aurora`、`hybrid` の CRUD、楽観ロック競合、ページングを検証した。Hybrid は JVM ワーカーから PostgreSQL に反映され、Native の検索 API で取得できた。

```sh
BENCH_NATIVE_QUICK=1 BENCH_DATASET_SIZE=1000 BENCH_WARMUP_SECONDS=1 \
  BENCH_DURATION_SECONDS=3 BENCH_REPETITIONS=1 make benchmark-native
```

Aurora モードの同じ1,000件に対し、プール上限8、1 VU、JSON ログの設定を揃えて比較した。HTTP エラーとページ検証エラーは両方とも0件。

| 指標 | JVM | Native Image (`-Ob --parallelism=4`) |
| --- | ---: | ---: |
| 起動から TCP ポートまで | 3,393.1 ms | 107.5 ms |
| 初回の単件 GET 応答 | 806.8 ms | 35.5 ms |
| 一覧 p50 / p95 / p99 | 4.96 / 18.80 / 34.01 ms | 1.58 / 5.29 / 9.71 ms |
| スループット | 133.86 req/s | 355.28 req/s |
| 負荷直後の RSS / 最大 RSS | 250.5 / 250.5 MiB | 139.4 / 139.4 MiB |
| ビルド実時間 (`installDist` / `nativeCompile`) | 27.89秒 | 365.51秒 |

コンパイラ単体は5分28秒で実行ファイルを生成した。出力は159.52 MB、コンパイラのピーク RSS は5.87 GBだった。最終版の全 Native モード検証は `-Ob` で実施した。修正後の `-O2` ビルドと、既定の30秒・3試行での全測定は未実施。

### 解釈と測定範囲

起動と同期は確認間隔の影響を受ける。常駐メモリにはリクエスト処理と起動時のロードが含まれる。k6 と API と DB は同じマシンの CPU・メモリを共有する。JVM と Native は起動時の処理、最適化、ガベージコレクターにも実装差がある。DynamoDB Local と PostgreSQL の測定値は、このローカル構成で操作や設定を比較する値として読む。実環境の DynamoDB や Aurora の性能と料金は、対象環境で別途測定する。

## AWS で比較する場合の手順

Aurora モードでの比較の基準例。各測定ではこのうち1項目だけを変更する。

```hcl
database_type            = "aurora"
api_memory_mb            = 1024
api_reserved_concurrency = 10
enable_api_snapstart     = false
enable_rds_proxy         = false
```

承認済みの検証環境で、Lambda のメモリ割り当て、予約済み同時実行数、公開バージョンでの SnapStart の有無、RDS Proxy の有無を1条件ずつ変える。固定した負荷で CloudWatch の `Duration`、`Errors`、`Throttles`、`ConcurrentExecutions`、ログの `Init Duration` または `Restore Duration`、データベース接続数と Proxy の接続待ち時間を収集する。コールドとウォームを区別し、使用リージョン、設定、料金計算に使った単価を記録する。SnapStart を比較する場合は `PublishedVersions` を使い、対象バージョンまたはエイリアスにルーティングする。今回の測定範囲はローカルに限定する。 [Lambda SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html) · [RDS Proxy のメトリクス](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.monitoring.html)
