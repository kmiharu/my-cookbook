# Spring BatchをAWS ECSの単発タスクで実行する

この手順では、ローカルと同じDockerfileからイメージを作り、FargateのStandalone Taskとして1回起動します。AWSでのapply、デプロイ、実行は未実施です。Terraformのmock検証とRunTaskクライアントのスタブ試験は、末尾のコマンドで再現できます。

## 既存VPCで実行するか、検証用Auroraごと作成する

| 何ができるか | Terraformの場所 |
| --- | --- |
| 既存DB・VPC・バケット・DynamoDBを使う | [terraform/existing](terraform/existing) |
| 検証用のVPC・Aurora・バケット・DynamoDBをまとめて用意する | [terraform/new](terraform/new) |
| state専用S3とロックファイル用IAMポリシーを用意する | [terraform/bootstrap](terraform/bootstrap) |
| 相手先アカウント用のbucket・KMSポリシー文と信頼されたロールを用意する | [terraform/partner-policy](terraform/partner-policy) |

両方の実行rootでECR、ECS Cluster、Task Definition、TaskRole、ExecutionRole、CloudWatch Logsを同じmoduleから定義します。既存環境のDBは `db_url` と `db_secret_arn`、接続経路は `subnet_ids` と `security_group_ids`、S3とDynamoDBは名前またはARNで受け取ります。DynamoDBのリージョンを変更する場合は `dynamo_region` と対象テーブルのARNを揃えます。移行先PostgreSQLを使う場合は `target_db_url` と `target_db_secret_arn` を対で指定します。

新規rootはAurora PostgreSQL 16.15のServerless v2ライター、2つのAZのプライベートサブネット、アプリからDBへの専用Security Group、NAT経路を作ります。NATは検証用に1 AZへ配置します。リージョンとAZでエンジン版・インスタンスタイプが提供されていることを実際のapply前に確認します。S3にはバージョニング、公開遮断、KMS既定暗号化、7日経過した未完了multipart uploadの回収を設定します。DynamoDBの既定はオンデマンド、PITRと削除保護が有効です。業務テーブルは `pk` / `sk` と `by-status` GSI、冪等記録は `operation_id` で検索します。冪等記録のTTLは既定で無効です。有効にするときは `expires_at` を再送可能期間より後に設定します。実際のTTL削除には遅延があります。

NATを使う既存プライベートサブネットでは、S3、DynamoDB、ECR、CloudWatch Logs、Secrets Manager、必要に応じてSTSへのHTTPSと、DBのTCP 5432を許可します。NATの代わりにエンドポイントを配置する場合は、S3とDynamoDBのGateway Endpoint、ECR APIとECR Docker、Logs、Secrets Manager、STSのInterface Endpointを検討します。ECRのイメージレイヤー取得用S3への到達性も確認します。エンドポイントのポリシー、プライベートDNS、Security Group、クロスリージョンの宛先への経路を実環境で検証してください。

## DBのマイグレーションと通常バッチの認証を分ける

JDBC URLには `sslmode=verify-full` とCAパス `sslrootcert=/opt/batch/certs/rds-global-bundle.pem` を指定します。CAバンドルはアプリのイメージに含まれます。既存の自己管理PostgreSQLを使うときは、そのサーバーの検証用CAをイメージ内で参照できるように準備します。DBのログイン情報は、`username` と `password` を持つSecrets ManagerのJSONからECSが注入します。実行環境変数へ平文値を書いたり、JDBC URLやJob引数へ追加したりしないでください。カスタマー管理KMSキーでSecretを暗号化する場合は、キーARNを `execution_kms_key_arns` に渡し、鍵ポリシーでもExecutionRoleを許可します。

新規rootが発行する `admin_secret_arn` はスキーマ準備用です。`batch_secret_arn` の値は、DB管理者が通常バッチ用ロールを作成した後、承認された秘密管理手順で設定します。通常バッチ用Secretの値をTerraformへ渡す必要はありません。専用DBで専用スキーマを用意する場合の管理者操作は次のとおりです。`migration_login` は管理用の移行ロールに置き換えます。

```sql
CREATE ROLE batch_runtime LOGIN;
CREATE SCHEMA batch_app AUTHORIZATION migration_login;
GRANT CONNECT ON DATABASE batch TO batch_runtime;
GRANT USAGE ON SCHEMA batch_app TO batch_runtime;
ALTER ROLE migration_login IN DATABASE batch SET search_path = batch_app;
ALTER ROLE batch_runtime IN DATABASE batch SET search_path = batch_app;
ALTER DEFAULT PRIVILEGES FOR ROLE migration_login IN SCHEMA batch_app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO batch_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE migration_login IN SCHEMA batch_app
  GRANT USAGE, SELECT ON SEQUENCES TO batch_runtime;
```

管理者は `psql` の `\password batch_runtime` 等でログインを設定してください。DBへ接続できるVPC内の管理ホストから移行ロールで同じイメージを起動し、業務とSpring Batchのテーブルを作成します。`maintenance.env` には Secret から注入する `BATCH_DB_URL`、`BATCH_DB_USER`、`BATCH_DB_PASSWORD` が必要です。

```bash
docker run --rm --env-file /secure/path/maintenance.env "$image_uri" job=Migrate runId=schema-20261127-01
```

既存スキーマでは既存テーブルとシーケンスへ同等の権限を一度付与します。Flyway履歴に通常バッチからの変更が不要なら、DB管理者として `REVOKE ALL ON batch_app.flyway_schema_history FROM batch_runtime` を実行します。通常のJobはDB管理者のログインを必要としません。リリース時は実行を止めてから管理用の移行を行い、必要なスキーマ版に更新した後に新しいイメージを使います。

## stateを分離してから、イメージをECRへ登録する

Terraform 1.17.2、AWS Provider 6.74.0、AWS CLI v2、Docker Buildx、Bash、jqを使用します。以下はAWS接続後にオペレーターが実行する例です。コマンドは `spring-batch-examples/` がカレントディレクトリです。

```bash
cp infra/terraform/bootstrap/terraform.tfvars.example infra/terraform/bootstrap/terraform.tfvars
terraform -chdir=infra/terraform/bootstrap init
terraform -chdir=infra/terraform/bootstrap plan
terraform -chdir=infra/terraform/bootstrap apply
```

作成したS3を使うTerraform実行ロールへ、bootstrapの `backend_operator_policy` で示す権限を付与します。state本体とS3ロックファイルのパスをアカウントとrootごとに分けます。業務データS3は別です。bootstrap rootのローカルstateもアクセスの制限された場所に保管します。環境が既にある場合は `root=infra/terraform/existing` を選びます。

```bash
root=infra/terraform/new
cp "$root/terraform.tfvars.example" "$root/terraform.tfvars"
cp infra/terraform/backend.hcl.example "$root/backend.hcl"
# tfvars と backend.hcl の例示値を対象環境に置き換える
terraform -chdir="$root" init -backend-config=backend.hcl
terraform -chdir="$root" plan
terraform -chdir="$root" apply

image_uri=$(infra/ecs/build-push.sh "$root" "release-$(git rev-parse --short HEAD)")
terraform -chdir="$root" plan -var="image_uri=$image_uri"
terraform -chdir="$root" apply -var="image_uri=$image_uri"
```

初回は `image_uri` を空にしてECRを作成します。イメージをpushした後はECRのdigestを構成へ渡すとTask Definitionが登録されます。以降のplanでも同じ値を渡すか、秘密情報を含まない環境のtfvarsへ保存します。ECRタグはimmutableです。ビルドし直した内容には新しいタグを使います。Task Definitionの既定はLinux/X86_64、1 vCPU、4 GiB、JVMは `-Xmx512m` です。ARM64を選ぶ場合はビルドを `linux/arm64` に揃えます。1/2 vCPUは4 GiBで比較できます。4 vCPUは8 GiB以上、8 vCPUは16 GiB以上を割り当てます。Fargateへの配置・イメージ取得・起動時間は、アプリログの処理時間と分けて集計します。

## 宛先のアカウントごとにS3権限を設定する

`partner` に相手先の `bucket`、`region`、任意の `prefix` を設定します。同じTaskRoleを使う場合、相手先のbucket policyで送信元の `task_role_arn` を許可してください。SSE-KMSの場合は相手先が管理するカスタマー管理キーのポリシーでも許可し、送信側の `task_kms_key_arns` にキーARNを指定します。AssumeRole方式では、相手先がTaskRoleを信頼するロールを作成し、そのARNを `partner.role_arn` に設定します。JavaはSDKの標準認証チェーンからTaskRole資格情報を取得し、必要な宛先でのみSTSを呼びます。

[相手先のroot](terraform/partner-policy) は、ポリシーへ組み込む文を出力します。既存bucketとKMSキーの所有者が現行ポリシーへ差分を統合します。HeadObjectで未作成キーを404として判定するため、例のポリシーは対象bucketに `s3:ListBucket` も付けます。宛先bucketを専用にするか、この許可範囲を相手先と調整してください。Object OwnershipをBucket owner enforcedにすればアップロード時にACLの指定が不要になります。相手側のロックファイルとstateは相手のアカウントで管理します。`terraform_operator_role_arn` はTerraform AWS provider aliasが使う運用管理用のロールです。アプリがSTSで引き受ける `partner.role_arn` は配送用です。

## 1つのJobを起動して終了を確認する

RunTaskを呼ぶIAMロールには、このTask Definitionの `ecs:RunTask` と、TaskRoleおよびExecutionRoleに対する `iam:PassRole` を付与します。`iam:PassedToService=ecs-tasks.amazonaws.com` で制限できます。結果確認には `ecs:DescribeTasks` とCloudWatch Logsの参照権限、任意停止に `ecs:StopTask`、起動応答を失ったときの追跡に `ecs:ListTasks` を付与します。ECRへpushする役割には、ECR認証・イメージ登録・参照の許可を別に与えます。

```bash
ECS_WAIT_SECONDS=1800 infra/ecs/run-task.sh "$root" \
  job=WorkTableExport runId=export-20261127-01 output.compression=gzip
```

スクリプトはTerraformから必要な非秘密outputだけを名前指定で取得します。タスク定義のリビジョン、イメージdigest、Job、runId、owner、task ARN、CloudWatch Logsの参照先を表示します。引数ごとの文字列をJSON配列に変換し、タスクの受理後はSTOPPEDまで待ちます。終了コード0は対象コンテナの正常終了です。起動失敗、OOM、exitCode欠落はスクリプトの終了コード70、RunTaskの受理失敗は69、待機期限に達した場合は124です。通常のJob失敗はコンテナの終了コードを返します。待機期限に達したタスクはARNから状態を確認できます。

ECSの `startedBy` と台帳のownerに同じ識別子を渡します。RunTaskの応答が失われた場合は表示済みownerでECSのタスクを検索してください。失敗や停止からの通常再開では、前回と同じJob・runId・処理引数を渡します。SIGKILLやOOMでACTIVEが残った場合は前タスクのSTOPPEDを確認し、DB台帳のowner_locationとSpring Batchの失敗試行IDを確認してから、同じ引数に次を加えます。

```bash
infra/ecs/run-task.sh "$root" job=WorkTableExport runId=export-20261127-01 \
  output.compression=gzip recover.owner="$previous_owner" recover.executionId="$execution_id"
```

`aws ecs stop-task` はSIGTERMを送り、協調停止の猶予は最大120秒です。強制終了後はアプリが実行所有権と成果物を照合し、未完了multipart uploadは後続処理またはS3のライフサイクルで回収します。

## AWSへ接続せず構成と起動スクリプトを検証する

```bash
infra/terraform/verify.sh
```

2026-11-27のローカル検証では、整形チェック、4 rootと3 moduleのbackend無効化init・validate、mock providerによるplan 8件、AWS CLIスタブ試験8件が成功しました。失敗とスキップは0件です。[検証ログ](verification.log)providerの初回取得にはHashiCorp配布先へのネットワーク接続が必要です。実ECS、Auroraへの接続、実IAM/KMS権限、相手先バケット、実ネットワーク、Service Quotasは未検証です。

検証用環境を将来整理するときは、実行中タスクが終了し、保存が必要な成果物・監査・スナップショットが保持されていることを確認します。Aurora・DynamoDBの削除保護を外す変更を確認してから、専用の検証rootでdestroy planをレビューします。必要なときだけ `skip_final_snapshot` と `force_destroy_buckets` を環境単位に変更します。既定は最終スナップショット作成、S3の強制削除無効です。ECRのイメージを整理してからリポジトリを廃止します。backendのstateバケットは他rootのstateを保持している間は存続させます。


参照資料は、[ECS Standalone Task](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/standalone-tasks.html)、[Fargate Task Definitionの制約](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html)、[Aurora Serverlessの作成](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.create.html)、[Terraform 1.17.2の配布](https://releases.hashicorp.com/terraform/1.17.2/)、[AWS Provider 6.74.0](https://registry.terraform.io/providers/hashicorp/aws/6.74.0/docs)、[S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)、[Terraform provider mocking](https://developer.hashicorp.com/terraform/language/tests/mocking)です。
