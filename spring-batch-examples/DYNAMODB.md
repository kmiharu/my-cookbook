# DynamoDBから顧客を書き出し、DBやDynamoDBへ反映する

## ローカル環境で8シナリオを通す

```sh
./scripts/setup-local.sh
docker compose --profile batch build batch
./scripts/dynamodb-scenarios.sh
BATCH_TEST_DYNAMO_ENDPOINT=http://127.0.0.1:18000 ./gradlew :batch-dynamodb:test
```

実行スクリプトはシナリオ固有のS3入力を作り、DynamoDBの項目、PostgreSQLの行、S3上の成果物を照合します。テストの入力世代と実行IDはスクリプトの実行ごとに変わります。故障注入は `local,fault-test` でのみ使い、DynamoDBの成功後かつPostgreSQLで配送済みと記録する前に更新Jobを失敗させます。同じrunで再開すると、操作記録の照合で加算が1回に留まります。

## キーでQueryし、固定した値を出力する

- 業務テーブルの `pk` は入力世代、`sk` は世代内の顧客IDです。`by-status` GSIは `gsi_pk=status` と、世代と顧客IDを結合した `gsi_sk` を使います。業務テーブルのキーとGSIは文字列です。操作記録は別テーブルに `operation_id` を主キーとして保存します。
- 通常のQueryは `pk` をキー条件にします。GSIのQueryは `dynamo.gsi=true dynamo.status=ACTIVE` で指定し、statusをキー条件、世代を読取後フィルターにします。Scanはテーブル全体を評価してから指定世代で絞ります。FilterExpressionの前後は `ScannedCount` と `Count` で区別します。GSIは結果整合性で読み、強い整合性を要求する組み合わせは起動時に拒否します。
- Query/Scanの結果はページ単位でPostgreSQLワークに保存し、型付きの最終キーを同じトランザクションで更新します。空ページでも最終キーがあれば続けます。読取完了後にキー順でCSVを作り、Scanの返却順が変わっても固定後の出力順は一定です。抽出が終わるまで書き手が変更しない入力世代を用意します。全体の単一時点を求める場合は、時点を固定できるエクスポート経路を別に設計します。
- CSV/TSVの基本列は `pk,sk,version,status,balance,memo_state,memo` です。`balance` はDynamoDBの範囲を検証した任意精度10進数です。`memo_state` の `ABSENT`、`NULL`、`VALUE` で属性なし、NULL、文字列を区別します。空文字を保存するには `VALUE` と引用された空文字を指定します。モデルにない属性や型はエラーにします。DynamoDBからPostgreSQLへ反映するときは `sk` に正規形式の正のbigintを要求し、NULL・属性なしの氏名はサンプル用の既定値を使います。
- 主な設定は `batch.dynamo.table`、`batch.dynamo.operations-table`、`batch.dynamo.index`、`batch.dynamo.region` です。実行設定では `dynamo.partition`、`dynamo.gsi`、`dynamo.status`、`dynamo.readMode`、`dynamo.consistentRead`、`dynamo.expectedItems`、`dynamo.pageLimit`、`dynamo.batchSize`、`dynamo.workers`、`dynamo.rateLimit`、`dynamo.retryAttempts`、`dynamo.retrySeconds` を使います。endpoint overrideとダミー認証はlocalプロファイルで使い、ECSはSDKの標準認証チェーンを使います。

## 既存項目を更新するか、専用世代へ投入する

- `DynamoDbImport` の既定は初回登録です。既存キーには条件付きPutが失敗します。全項目を置換する場合は `dynamo.writeMode=replace` と `dynamo.partition=generation:<名前>` を使います。初回投入時には空の世代を作り、配送完了までアプリが他の書込みを拒否します。外部の書込みも同じ期間停止します。BatchWriteは最大25項目、項目ごとの400 KiBと要求の16 MiBを保守的に検査し、未処理項目だけを再送します。
- `DynamoDbConditionalUpdate` はversionを照合して列を更新します。入力の `version` は期待する更新前の値です。`memo_state=ABSENT` は既存のmemoを維持します。`dynamo.operation=add` の列は `pk,sk,version,delta` です。`DynamoDbDelete` の列は `pk,sk,version` です。いずれも操作IDとpayload hashを条件付き変更と同じDynamoDBトランザクションで確定し、同じ操作IDで内容が異なる再送は衝突として停止します。操作記録は再実行期間を通して保持します。
- `PostgreSqlToDynamoDb` の既定は固定ワークからの初回配送です。`dynamo.operation=outbox dynamo.status=INACTIVE` はソースDBのstatus変更とoutbox作成を同じPostgreSQLトランザクションで確定します。事前に同じ `dynamo.partition` へ初回配送し、他の更新系とversion規約を共有します。キー別の先行versionを配送してから後続を送ります。DynamoDB側の成功は配送記録とは別に確定するため、未確認分を操作IDで安全に再送します。
- HTTP試行とSDK呼出しはそれぞれ期限付きです。DynamoDBの書込みはスロットリングや未処理項目を再試行し、条件競合や権限不備は失敗として返します。配送ステップとレポート出力は別に管理し、出力だけの再開では業務操作を再実行しません。

## 同じ入力世代でQueryとScanを測る

```sh
./scripts/dynamodb-benchmark.sh 1000000 ddb-million
DDB_BENCH_SOURCE=generation:ddb-million DDB_BENCH_SKIP_SEED=1 DDB_BENCH_MODE=SCAN \
  ./scripts/dynamodb-benchmark.sh 1000000 ddb-million-scan
DDB_BENCH_SOURCE=generation:ddb-million DDB_BENCH_SKIP_SEED=1 DDB_BENCH_PAGE_LIMIT=100 \
  DDB_BENCH_BATCH_SIZE=10 DDB_BENCH_WORKERS=2 DDB_BENCH_TARGET=generation:ddb-million-copy \
  ./scripts/dynamodb-benchmark.sh 1000000 ddb-million-copy
```

毎回新しい試行名を指定します。最初のコマンドはseed 31から入力生成と登録を行います。後続のコマンドは同じ入力世代を読み、配送比較では各試行専用の空世代に書き込みます。投入、読取と固定、結果検証のログを分けます。結果は格納バイトサイズ、行数、順序、内容を検証し、アプリとSDKの呼出し・再試行数、Count/ScannedCount、RSS・CPU・GCの観測を記録します。ウォームアップを除いて構成ごとに3回以上実行し、他の大量処理と実行時刻を分けます。

DynamoDB Localはprovisioned throughputを再現せず、ScanのSegment設定を無視します。実APIの確認とは別に、空ページ、未処理項目、トランザクション競合、応答喪失をSDK境界で試験します。本番のスロットリング、ホットパーティション、GSI伝播時間、費用・スループットはAWSで計測します。

[Query API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html) · [BatchWriteItem API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_BatchWriteItem.html) · [DynamoDB Local](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.UsageNotes.html)

実サービスの少量試験とベンチマークの実行記録は [DynamoDB Localの検証結果](bench-results/dynamodb-local.md) を参照してください。

準備だけを別の時間帯に実行するには `DDB_BENCH_PREPARE_ONLY=1` を指定します。固定済みのS3入力を再利用するには `DDB_BENCH_RESUME_SEED=1 DDB_BENCH_INPUT_KEY=benchmarks/dynamodb/<試行名>.csv.gz` を指定します。別のローカル検証サービスを構成した場合は、Docker起動時に `DDB_BENCH_DYNAMO_ENDPOINT` と `DDB_BENCH_DATABASE_URL` を使って接続先を切り替えられます。
