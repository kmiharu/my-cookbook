# PostgreSQLの顧客をCSVで配布し、受信データを反映する

Java 21、Spring Batch 6.0、MyBatis、PostgreSQL、S3、DynamoDBを組み合わせたサンプルです。[49シナリオ](./SCENARIOS.md)に、準備データ、コマンド、期待結果と再開方法を記載しています。

| できること | 手順 |
| --- | --- |
| 顧客を抽出し、2バケットに同じgzipを配布する | [ローカルで起動して出力する](#ローカルで起動して顧客をcsvで出力する) |
| 入力の版とチェックサムを固定し、DBに反映する | [取込を試す](#受信csvを検証して顧客を更新する) |
| 業務データの修正案を確認、適用、復元する | [16 DataPatch](./SCENARIOS.md)・[業務更新の実装](./docs/operations.md) |
| PostgreSQLとDynamoDBの間でデータを配送する | [42〜49 DynamoDB](./SCENARIOS.md)・[DynamoDB連携の実装](./DYNAMODB.md) |
| 停止後に同じ実行を再開する | [実行境界と復旧](./DESIGN.md) |
| 同じイメージをECSタスクで起動する | [TerraformとECS](./infra/README.md) |
| 100万行・1,000万行の資源消費を測る | [計測手順](./batch-test-support/README.md) |

## ローカルで起動して顧客をCSVで出力する

Docker Engine、Docker Compose v2、Bash、Python 3、jqを使います。ホストからGradleを使う場合はJava 21のJDKも用意してください。AWSの接続は不要です。対象リポジトリのルートから実行します。

```bash
cd spring-batch-examples
cp .env.example .env
./scripts/setup-local.sh
docker compose --profile batch build batch
docker compose --profile batch run --rm -e BATCH_TARGET_DB_URL= batch job=Migrate runId=local-schema-01
docker compose --profile batch run --rm batch job=Seed runId=seed-01 rows=100 rowWidth=256
docker compose --profile batch run --rm batch job=WorkTableExport runId=export-01 destinations=both output.compression=gzip
```

この起動例は出力元のDBを準備します。移行先DBを準備する手順は[別PostgreSQLへの移行](./docs/operations.md)にあります。

`batch-internal` と `batch-partner` に `WorkTableExport/export-01/customers.csv.gz` と `manifest.json` ができます。結果をストリームで確認します。

```bash
docker compose exec -T awscli aws --endpoint-url http://s3:8333 s3 cp \
  s3://batch-internal/WorkTableExport/export-01/manifest.json - --only-show-errors
for bucket in batch-internal batch-partner; do
  docker compose exec -T awscli aws --endpoint-url http://s3:8333 s3 cp \
    "s3://$bucket/WorkTableExport/export-01/customers.csv.gz" - --only-show-errors | sha256sum
done
```

出力のSHA-256はS3に格納されたgzipバイト列に対する値です。ETagは版の照合や条件付きアクセスに使います。

## 受信CSVを検証して顧客を更新する

```bash
fixture=$'id,name,email,status\n900001,山田,example@example.test,ACTIVE\n'
printf '%s' "$fixture" | docker compose exec -T awscli aws --endpoint-url http://s3:8333 s3 cp \
  - s3://batch-input/import-01.csv --only-show-errors
sha=$(printf '%s' "$fixture" | sha256sum | cut -d' ' -f1)
docker compose --profile batch run --rm batch job=CustomerUpsert runId=import-01 \
  input.key=import-01.csv "input.sha256=$sha" input.rows=1
docker compose exec -T postgres psql -U cookbook -d cookbook \
  -c "SELECT id, name, status, version FROM customer WHERE id=900001"
```

既存IDの値を変更したときはversionが増えます。入力を差し替えた場合は、新しいS3キーかオブジェクト版と新しいrunIdを割り当てます。取込エラーを許容する例は `ValidatedImport skipLimit=1` です。引用が閉じない場合やgzip終端が壊れた場合は実行を中断します。

## Jobの設定とファイルの書式を変える

Spring設定は `--spring.profiles.active=local`、`--spring.config.additional-location=file:/path/options.yml` または環境変数で渡し、Job選択と実行引数は `job=...`、`runId=...` のように渡します。設定値は実行引数、ファイル個別設定、Job設定、共通デフォルトの順に解決します。JobParametersに永続化する識別値はrunIdです。解決済み非秘密設定と版は実行台帳に保存します。

| できること | 引数と既定値 |
| --- | --- |
| DBの期間と状態を絞る | `sql.fromDate`、`sql.toDate`、`sql.status`。日付はUTC開始日以上・終了日未満 |
| 入出力をCSV/TSVやgzipにする | `input.` または `output.` に `format=csv`、`compression=none`、`gzipLevel=6` |
| 文字コード、引用、改行を指定する | `charset=UTF-8`、`header=true`、`bom=false`、`lineEnding=lf`、`delimiter`、`quote`、`escape=double-quote`、`nullValue` |
| 列、日付、数値を指定する | `columns` はカンマ区切り、`columnNames` は同じ順でのヘッダ名、`dateFormat=uuuu-MM-dd`、`timeZone=UTC`、`numberFormat=plain`。利用できる列と書式はJobの列契約に従う |
| 1レコードを制限する | `maxColumns=128`、`maxColumnChars=8192`、`maxRecordChars=16384`。UTF-16コード単位で解析中に制限 |
| 出力先を選ぶ | `destinations=internal`、`partner`、`both`。バケット、prefix、region、任意ロールは環境変数 |
| 取得・書込・転送を調整する | `fetchSize=1000`、`chunkSize=1000`、`partSize=8388608`、`transferWorkers=1`、`totalBuffers=2`、`partitions=1` |
| 同じ版の複数ファイルを順次取り込む | `input.keys`、`input.sha256`、`input.rows` に同じ順序でカンマ区切りの値、任意で `input.readyKey` |
| パッチやDynamoDBの操作を指定する | `patchId`、`planId`、`dryRun=true`、`dynamo.*`。対象Jobの引数をカタログで確認 |

YAMLのマップキーをブラケットで囲むと、大文字やドットを維持できます。

```yaml
cookbook:
  batch:
    jobs:
      '[MultiFileExport]':
        options:
          '[output.compression]': gzip
        files:
          customer-members:
            '[output.format]': tsv
            '[output.header]': 'true'
```

BOMはUTF-8のみ対応します。入力と出力でWindows-31Jを選べます。変換できない文字はエラーです。既定のNULLは非引用空欄、空文字は引用付き空欄です。入力ヘッダは宣言した列順と一致させます。出力は既存列の射影・並べ替えをサポートします。業務ファイルのJSON対応はフォーマッター・パーサーの追加箇所から拡張します。

## 実行環境のバージョンを揃える

Gradle 8.14.8 Wrapper、Spring Boot 4.0.10 BOM（Spring Batch 6.0.6、pgJDBC 42.7.14、Flyway 11.14.1、Testcontainers 2.0.5）、MyBatis Starter 4.0.1、AWS SDK v2 BOM 2.59.10を使用します。ローカルのPostgreSQL 16.15、SeaweedFS 4.55、DynamoDB Local 3.3.0とJava実行イメージをdigestで固定しています。 [Spring Boot 4.0の対応Java/Gradle](https://docs.spring.io/spring-boot/4.0/system-requirements.html) [Batch 6.0の並列化仕様](https://docs.spring.io/spring-batch/reference/6.0/scalability.html) [MyBatis対応表](https://github.com/mybatis/spring-boot-starter/tree/mybatis-spring-boot-4.0.1)

## SQLとJobを追加する

| 追いたい処理 | 読み始めるファイル |
| --- | --- |
| 顧客をCSVで出力する | [StandardJobsのStep順](./batch-examples/src/main/java/cookbook/batch/examples/StandardJobs.java) → [出力と分割](./batch-examples/src/main/java/cookbook/batch/examples/CustomerExportSteps.java) → [抽出SQL](./batch-examples/src/main/resources/mapper/CustomerMapper.xml) |
| 受信CSVを検証して反映する | [Chunk取込と反映](./batch-examples/src/main/java/cookbook/batch/examples/CustomerImportSteps.java) → [論理レコードとチェックポイント](./batch-examples/src/main/java/cookbook/batch/examples/CustomerInputReader.java) |
| PostgreSQLのCOPYを使う | [COPYの取込・出力手順](./batch-examples/src/main/java/cookbook/batch/examples/CustomerCopy.java) → [pgJDBCアダプター](./batch-database/src/main/java/cookbook/batch/database/PgCopy.java) |
| S3の片側成功から再開する | [宛先をまとめる処理](./batch-storage/src/main/java/cookbook/batch/storage/MultipartExporter.java) → [宛先別の照合・確定](./batch-storage/src/main/java/cookbook/batch/storage/S3ArtifactPublication.java) |
| DynamoDBから読み取り、配送する | [DynamoDBのJob定義](./batch-examples/src/main/java/cookbook/batch/examples/dynamo/DynamoJobs.java) → [ページ読取とワーク](./batch-examples/src/main/java/cookbook/batch/examples/dynamo/DynamoWork.java)・[配送と確認](./batch-examples/src/main/java/cookbook/batch/examples/dynamo/DynamoDelivery.java) |

抽出・更新のSQLは `batch-examples/src/main/resources/mapper/` に追加します。条件をDTOに定義し、Mapper XMLの `#{...}` に渡してください。公開する業務操作は型付きRepositoryメソッドで選びます。Mapper IDや識別子をCLIに公開すると、SQLをレビュー済みの範囲に限定できなくなります。

業務JobはSpring BatchのStepとJobで構成し、入力の前処理、Chunk、検証、反映、出力を分けます。Jobを登録するときは起動時の許可・検証、Mapper、マイグレーション、カタログの実行例、結果照合を同時に追加してください。

## 実サービスで結果を照合する

```bash
# Java 21 JDKで実行
BATCH_S3_TEST_ENDPOINT=http://127.0.0.1:18333 \
BATCH_TEST_DYNAMO_ENDPOINT=http://127.0.0.1:18000 \
  ./gradlew clean check :batch-examples:bootJar
./scripts/verify-local.sh
./scripts/verify-standard-scenarios.sh
./scripts/operations-scenarios.sh
./scripts/dynamodb-scenarios.sh
./scripts/verify-restart-s3.sh
./scripts/verify-chunk-recovery.sh
./scripts/verify-stop-local.sh
./scripts/verify-run-ownership.sh
./infra/terraform/verify.sh
```

[検証記録](./VERIFICATION.md)に実行した環境、テスト結果、計測条件を置きます。練習環境を停止するには `docker compose --profile tools --profile batch down` を使います。永続ボリュームは次回の実行で再利用できます。
