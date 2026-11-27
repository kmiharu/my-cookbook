# AWS向けの構成を静的に確認する

Terraform は AWS 向けの参照定義です。SAM は同じ JVM 成果物を使うローカル検証用です。今回の検証範囲は HCL と Provider スキーマの検証、全 Provider をモックした構成確認までです。AWS と Cloudflare の認証情報は不要です。

```sh
make test-iac
```

`api-sample/` で上のコマンドを実行します。Terraform 1.13.5、AWS Provider 6.20.0、Cloudflare Provider 5.19.1 を使います。Provider の固定バージョンと配布物のチェックサムは [ロックファイル](../terraform/.terraform.lock.hcl) にあります。個別の検証コマンドも同じディレクトリから実行できます。

```sh
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false -input=false
terraform -chdir=terraform validate
terraform -chdir=terraform test
```

[構成テスト](../terraform/tests/modes.tftest.hcl) は AWS と Cloudflare を明示的にモックし、DB ごとのリソース分岐と参照を確かめます。接続性やサービス側の設定可否はローカルでは確認できません。実環境での作成、IAM の実効権限、ACM 検証、API 呼び出し、Lambda の性能測定は未検証です。[Terraform の Provider モック](https://developer.hashicorp.com/terraform/language/tests/mocking)

## DB モードと API を指定する

| できること | 変数 | 作成対象・必要な入力 |
| --- | --- | --- |
| DynamoDB だけで CRUD する | `database_type = "dynamodb"` | オンデマンドテーブルと一覧用の疎な GSI 2 個。API Lambda は VPC 外で実行する |
| Aurora PostgreSQL だけで CRUD する | `database_type = "aurora"` | Aurora Serverless v2、VPC、Secrets Manager エンドポイント。`pg_secret_arn` が必要 |
| DynamoDB を正本にして Aurora で検索する | `database_type = "hybrid"` | DynamoDB Streams、Aurora、同期 Lambda、S3 退避先、DynamoDB ゲートウェイエンドポイント。`pg_secret_arn` が必要 |
| HTTP API の payload 2.0 を使う | `api_type = "http"`（既定） | HTTP API と `$default` ステージ |
| REST API の payload 1.0 を使う | `api_type = "rest"` | REGIONAL REST API と `v1` ステージ |
| 既存ドメインで API を公開する | `domain_name = "api.example.com"` | 同じ AWS リージョンの ACM 証明書と API Gateway のドメイン。`cloudflare_zone_id` が必要 |
| RDS Proxy を経由する | `enable_rds_proxy = true` | PostgreSQL を使うモードで選択可能 |
| Lambda の公開版で SnapStart を使う | `enable_api_snapstart = true` | API Lambda の公開バージョンと `live` エイリアス |

AWS 標準パーティションのリージョンを想定し、既定値は `us-east-1` です。Aurora では `availability_zone_ids` にそのリージョンの 2 AZ を指定します。RDS Proxy を選択する場合は、対象 AZ でのサポートを事前に確認します。Aurora PostgreSQL は 16.11 を既定とし、直接接続にも Proxy 経由にも単一の `db.serverless` ライターを使います。容量範囲は 0.5〜2 ACU です。[Aurora Serverless v2 の要件](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.requirements.html) [Aurora PostgreSQL リリースノート](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraPostgreSQLReleaseNotes/AuroraPostgreSQL.Updates.html)

API と同期 Lambda は `java21`・`x86_64` で `app/build/distributions/api-lambda.zip` を共有します。変数 `lambda_zip_path` の相対パスは `terraform/` を基準とします。Gradle がアプリと依存ライブラリの JAR を ZIP の `lib/` に格納します。公式の Micronaut ハンドラーを payload に合わせて選択し、同期は `cookbook.api.sync.SyncHandler` を使います。[Java Lambda の ZIP 形式](https://docs.aws.amazon.com/lambda/latest/dg/java-package.html) [Micronaut AWS のハンドラー](https://micronaut-projects.github.io/micronaut-aws/latest/guide/)

## Aurora に私設ネットワーク経由で接続する

VPC に 2 つのプライベートサブネットを置きます。Aurora を使う Lambda の Security Group は PostgreSQL の TCP 5432 と Secrets Manager エンドポイントの TCP 443 を許可します。Proxy を選択すると Lambda → Proxy → Aurora の各区間で別のルールを使います。

Hybrid の API Lambda だけが DynamoDB ゲートウェイエンドポイントへ TCP 443 でアクセスできます。SDK はリージョンの DynamoDB エンドポイントを使います。Streams の読み取りと失敗先への配送は Lambda のイベントソースマッピングが行います。VPC に NAT Gateway は不要です。[DynamoDB ゲートウェイエンドポイント](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-ddb.html) [Secrets Manager の VPC エンドポイント](https://docs.aws.amazon.com/secretsmanager/latest/userguide/vpc-endpoint-overview.html) [SDK のアカウントベースエンドポイント設定](https://docs.aws.amazon.com/sdkref/latest/guide/feature-account-endpoints.html)

Aurora が管理者パスワードを Secrets Manager に保存します。アプリ用には同じリージョンとアカウントに別のシークレットを用意し、`pg_secret_arn` で ARN を渡します。値は `username` と `password` の JSON オブジェクトです。シークレットの値を Terraform で取得する処理はありません。カスタマー管理 KMS キーを使う場合は `pg_secret_kms_key_arn` を指定し、キー側の許可も設定します。[Aurora 管理者パスワードと Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-secrets-manager.html)

将来の構築時は `migration_connection` 出力にあるサブネットと Security Group を使い、別途用意したプライベート実行環境からマイグレーションを行います。管理者シークレットを取得する権限は、その実行環境に限定します。DDL 実行後、アプリ用シークレットと同じ認証情報で PostgreSQL ログインロールを作成し、必要なテーブルへの権限を付与します。Proxy 選択時の DB ロールは SCRAM-SHA-256 のパスワードを使います。データ投入や API 利用はマイグレーション後に開始します。

JDBC は `sslmode=verify-full` を使います。Aurora に直接接続するときは ZIP 内の AWS RDS CA バンドルを使います。RDS Proxy が提示する ACM 証明書の検証には JVM のトラストストアを使います。[RDS の TLS と CA](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) [RDS Proxy の TLS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.howitworks.html)

## 同期の失敗レコードを退避する

Hybrid は `NEW_AND_OLD_IMAGES` の DynamoDB Streams を `TRIM_HORIZON` から処理します。イベントソースマッピングは最大 5 件ずつ渡し、失敗したレコードの `SequenceNumber` を `ReportBatchItemFailures` で受け取ります。最小の失敗シーケンス以降は再処理され得ます。関数エラー時のバッチ分割を有効にし、再試行回数は 5 回、レコードの最大経過時間は 1 時間です。同期 Lambda のタイムアウトは 75 秒とし、DB 障害時の接続・読み取り待ちを含めて部分応答を返す時間を確保します。[部分バッチ応答の仕様](https://docs.aws.amazon.com/lambda/latest/dg/services-ddb-batchfailurereporting.html)

同期実行ロールのレコード読み取り権限は、対象テーブルのストリーム ARN に限定します。`ListStreams` は IAM がストリーム単位の制約を提供していないため、リクエストリージョンで制限します。[DynamoDB の IAM アクションとリソース](https://docs.aws.amazon.com/service-authorization/latest/reference/list_dynamodb.html)

上限に達した呼び出しの情報とイベント本体を、暗号化した非公開の S3 バケットに 30 日間保存します。同期実行ロールの配送先は自アカウントのバケットに限定します。運用時は DB の復旧を確認し、退避オブジェクトの `requestPayload` から元イベントを取り出して再処理します。Streams のチェックポイントは AWS が管理します。[DynamoDB イベントソースの失敗先](https://docs.aws.amazon.com/lambda/latest/dg/services-dynamodb-errors.html)

## 独自ドメインと TLS を設定する

`domain_name` と `cloudflare_zone_id` の指定で、ACM の DNS 検証用 CNAME と API 接続用 CNAME を作成します。Cloudflare レコードは両方とも DNS only です。ACM の証明書は API Gateway と同じリージョンで発行し、検証完了後に Regional カスタムドメインに関連付けます。DNS ゾーンと API トークンは既存のものを将来の環境で利用します。トークンは Cloudflare Provider の環境変数から渡します。[Regional カスタムドメイン](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-regional-api-custom-domain-create.html) [Cloudflare DNS の Provider リファレンス](https://registry.terraform.io/providers/cloudflare/cloudflare/5.19.1/docs/resources/dns_record)

## 将来の AWS 検証で測定条件を揃える

API Lambda の CloudWatch Logs は 14 日保持します。HTTP API は JSON のアクセスログも保持します。REST API では Lambda ログを参照します。将来比較する場合は同じデータ、リージョン、リクエスト列で `api_memory_mb`、`api_reserved_concurrency`、`enable_api_snapstart`、`enable_rds_proxy` を一つずつ変えます。

各条件でコールド開始とウォームリクエストを分け、Lambda の `Init Duration`、`Restore Duration`、`Max Memory Used`、API のレイテンシとエラー率、RDS の接続数を記録します。SnapStart は `live` エイリアス経由で測定し、復元後の DB 接続と認証情報更新も確認対象にします。[SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html)

PostgreSQL の JDBC 接続は必要になった時点で開きます。アプリ用シークレットは実行環境の初期化時に取得するため、DB パスワードを変更した場合は新しい実行環境へ切り替えます。SnapStart 使用時は新しいバージョンを発行し、スナップショットが更新されたバージョンに `live` を切り替えます。[SnapStart のバージョンとスナップショット](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-activate.html)
