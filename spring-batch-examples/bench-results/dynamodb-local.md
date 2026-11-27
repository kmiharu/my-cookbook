# DynamoDB Localで8シナリオを照合する

2026-11-27にTemurin 21.0.13+9でホストのアプリケーションJARを起動し、ComposeのPostgreSQL 16.15、SeaweedFS 4.55、DynamoDB Local 3.3.0に接続した。ログの実行IDは `ddb-verify-c`。通常の再実行手順は `./scripts/dynamodb-scenarios.sh`。SDK試験は `BATCH_TEST_DYNAMO_ENDPOINT=http://127.0.0.1:18000 ./gradlew :batch-dynamodb:test` で7件成功し、失敗0件、skip 0件。内訳は実サービス1件とSDK境界試験6件。

| 確認した動作 | 結果 |
| --- | --- |
| 42 顧客をQueryとGSIから出力する | 主キー3件、statusを指定したGSI 2件。 |
| 43 顧客をScanして固定ワークから出力する | Scan 3件、Queryと格納バイトのSHA-256が一致。 |
| 44 gzip入力からDynamoDBに登録する | 条件付き新規登録3件、専用世代へのBatchWrite 3件。NULL、空文字、引用された改行を照合。 |
| 45 加算と部分更新を再開する | DynamoDB確定後の注入失敗ではPGの配送済みフラグはfalse。再開後も残高3.375、version 1。後続の部分更新でversion 2、既存memoは維持。 |
| 46 期待versionと照合して項目を削除する | 削除済みのキーがGetItemから消えたことを確認。 |
| 47 PostgreSQLの固定行とoutboxを配送する | 初回配送後にstatusを変更し、PG顧客とDynamoDB項目がversion 1・INACTIVE。対応するoutbox行は配送済み。 |
| 48 DynamoDBの2顧客をPostgreSQLへ反映する | 2件を反映。削除した項目は存在しない。 |
| 49 QueryとScanを読み比べる | QueryはCount 2・ScannedCount 2・3 API呼出し。ScanはCount 2・ScannedCount 116・59 API呼出し。専用世代への配送も確認。 |

## 100項目の測定手順を照合する

同じ `generation:ddb-bench-smoke` の100項目を実行し、キー順と全列をストリームで照合した。約120 B/行、seed 31、メモは64桁のSHA-256文字列。サンプルの動作確認中に別のPostgreSQL負荷試験が走っていたため、速度差の判断には使わない。

| 測った処理 | Page / Batch / Worker | 全体秒 | 読取 Count / ScannedCount / API | 配送 API | gzip |
| --- | --- | ---: | --- | ---: | ---: |
| QueryしてS3へ出力 | 1,000 / 25 / 2 | 16.964 | 100 / 100 / 1 | — | 4,677 B |
| Scanして別世代に配送しS3へ出力 | 25 / 10 / 2 | 30.403 | 100 / 118 / 5 | 11 | 4,677 B |

両出力のSHA-256は `c3421e0572337541da6ca5730a36f582e78c8f82c7ed1db66b5b76cafb2a9823`。SDK再試行、アプリ再試行、未処理項目は各0件。Scan試行のアプリ最大RSSは254,748 KiB、CPUは1,485 tick（100 Hz）、GC停止17回・584.557 ms。最初のQuery試行ではサンプラーが親シェルを観測していたため、そのRSSとCPUは採用せず、後続でJavaプロセスを直接観測するよう修正した。ホスト起動なので4 GiBコンテナ制限下として扱わない。

生ログは `bench-results/raw/ddb-verify-c/`、`bench-results/raw/ddb-bench-smoke/`、`bench-results/raw/ddb-bench-smoke-scan/` に生成される。負荷試験コマンドと入力世代の条件は [DYNAMODB.md](../DYNAMODB.md) を参照。

## 100万項目の準備で発生した制約

最初の試行は、同じ環境でPostgreSQLの1,000万行フィクスチャを生成している間に次のコマンドでDynamoDBの準備を開始した。

```sh
BATCH_IMAGE=spring-batch-examples:dynamo-million DDB_BENCH_PREPARE_ONLY=1 DDB_BENCH_WORKERS=8 \
  ./scripts/dynamodb-benchmark.sh 1000000 ddb-million
```

S3にgzipの100万行入力を格納し、ストリームGETでSHA-256を読んだ。バッチコンテナの起動がDocker VFSの `no space left on device` で失敗した。観測時の共有ディスク空きは約107 MiBで、DynamoDBへの登録は始まっていない。起動失敗ログは `bench-results/raw/ddb-million/seed.launch` に保存した。固定入力を再利用する場合は、`DDB_BENCH_RESUME_SEED=1` を指定し、同じS3オブジェクトを使って再開する。

その後、空きディスクを確保して同じS3入力を使い、隔離したPostgreSQLデータベースで100万行を解析・検証してワークをREADYにした。永続DynamoDB Localでは46,400件の配送確認を記録した時点で試行を停止した。測定用アプリはPID 1のJavaプロセスだった。SIGTERM後は配送件数が増えなかった一方、Stepが416,645回の管理情報コミットを記録してSTARTEDのまま残り、終了コードは143だった。ログは `bench-results/raw/ddb-million-retry/`。この試行の残りを再開する場合は、停止を確認してから既存のSTARTED回復手順を使う。

別の小規模試験でSIGTERM後のスレッドダンプを取得したところ、Spring Batch 6.0のTaskletStepは、指定された伝播属性でチェック例外がロールバック対象にならないとTaskletを繰り返していた。チェック例外をStepへ伝え、停止時にStepを終了対象として扱う共通処理に修正した。修正後は `./scripts/verify-restart-dynamodb.sh` で、SIGTERM後1秒未満にSTOPPEDを記録し、同じJobInstanceの次のJobExecutionで2/15件から15/15件へ進んだ。version 0の15個のキーをDynamoDBで照合した。ログは `bench-results/raw/ddb-signal-shared/`。 [Spring Batch 6.0.6 TaskletStep](https://github.com/spring-projects/spring-batch/blob/v6.0.6/spring-batch-core/src/main/java/org/springframework/batch/core/step/tasklet/TaskletStep.java)

## インメモリのDynamoDB Localで100万項目を用意する

同じLocal 3.3.0の公式JARを別ポートで `-inMemory -sharedDb -port 8001` として起動し、別テーブル・別PostgreSQLデータベースを作成した。通常の永続Localポート8000は少量結合・停止試験用に残した。100万行のgzip入力を再利用し、1000行Chunk、25件BatchWrite、8 Workerで新しい世代に登録した。

- 準備全体415.111秒。実サービスAPI 40,001回、アプリ・SDK再試行0回、未処理0件。PostgreSQLの配送確認は1,000,000件で、状態はAPPLIED。
- 準備中のアプリVmHWM最大423,488 KiB、CPUサンプル最大10,622 tick（100 Hz）、GC停止523回・2,280.270 ms。DynamoDB Localのインメモリ側プロセスの準備後VmHWMは1,287,192 KiB。準備には他の少量検証と実行時間が重なる区間があった。
- S3格納の入力SHA-256は `5382c7ebe946214ee689abdf57c60503fe267461bcf2b924b9826e23b214b830`。最大ヒープは512 MiB。コンテナに4 GiBを指定したが、rootless Dockerで観測できた `memory.max` はホスト共有の17,179,869,184 Bだった。アプリのRSSと共有cgroupのメモリを別に扱う。

代替の準備ログは `bench-results/raw/ddb-million-memory/`。 [DynamoDB Localの起動オプション](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.UsageNotes.html)

## 100万項目をQueryし、S3で全行を検証する

準備済みの同一世代 `generation:ddb-million` を、ページサイズ1,000、読取Worker 1でQueryした。固定ワークから内部S3バケットへgzipで出力した。使用コンテナのimage IDは `sha256:8e4be862abe86fb81e51f949781fbbb233fab0fd98bbdf8264d173966674c2ab` だった。

| 測った項目 | 結果 |
| --- | --- |
| 実行全体 | 163.062秒、約6,133行/秒 |
| Spring Batch実行 | 153.729秒 |
| QueryからPostgreSQL固定ワークまで | 146.104秒 |
| 固定ワークからS3へのgzip出力 | 7.548秒、出力中5.440 MiB/秒 |
| Queryで評価・返却した件数 | Count 1,000,000、ScannedCount 1,000,000。1,001 API呼出し、SDK・アプリ再試行0回 |
| S3に格納した量 | 43,056,064 B。解凍後116,100,045 B。圧縮後の比率37.09% |
| アプリのプロセス資源 | 141サンプルで最大VmHWM 379,776 KiB（370.875 MiB）、CPU 48.99秒、GC停止418回・合計1,063.110 ms、GC直前に観測した最大heap 153 MiB |
| インメモリDynamoDB Localのプロセス資源 | VmHWM 1,336,396 KiB、測定前後のCPU差106.12秒 |

アプリ終了後にS3 GETを開始し、全1,000,000行をストリームで照合した。キー順に全列をseed 31から再計算し、欠落・重複・値の違いがないことを確認した。別のS3 GETで格納バイトのSHA-256 `5ca99b70843d25de269219a2c3d8c6f8f76e3e9d5c47022250e6192a9d35e451` が台帳と一致した。照合時間は実行全体の数値から分けた。

生ログは `bench-results/raw/ddb-million-query/`。100万件の経路は1回の代表実行で、Scanと設定差の比較試験は上記の少量フィクスチャで実施した。DynamoDB Localの結果はAWSのスループットや料金の推定には用いない。
