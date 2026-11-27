# ローカルで実行した検証

検証環境は Linux x86_64、Docker Engine 29.9.2、Docker Compose 2.40.3 です。コンテナは DynamoDB Local 3.3.2、PostgreSQL 16.14、Temurin 21.0.13 を使用しました。実行環境の上限は4 CPU、16 GiB でした。

| コマンド | 結果 |
| --- | --- |
| `make verify` | 終了コード0。通常テスト、3モードの通常 HTTP と SAM、実 Streams 同期、IaC の順に通過 |
| `make build` | JVM 配布物、Java 21 Lambda ZIP を生成。ZIP 内の3種類のハンドラーと RDS CA バンドルを確認 |
| `make test` | JUnit、Micronaut Test、実 PostgreSQL の Testcontainers 計7件に成功 |
| `make test-e2e DB=dynamodb` | CRUD、競合、ページングに成功。独立したネットワークに PostgreSQL を起動せず実行 |
| `make test-e2e DB=aurora` | PostgreSQL 単独で CRUD、競合、ページングに成功 |
| `make test-e2e DB=hybrid` | DynamoDB への書き込み・単件取得と PostgreSQL の一覧反映、CRUD、競合、ページングに成功 |
| `make test-lambda DB=dynamodb` | `sam local start-api` の CRUD と `sam local invoke` の payload 2.0／1.0 に成功 |
| `make test-lambda DB=aurora` | PostgreSQL 単独で SAM の CRUD、payload 2.0／1.0 の直接呼び出しに成功 |
| `make test-lambda DB=hybrid` | SAM の CRUD と PostgreSQL 検索への反映、payload 2.0／1.0 の直接呼び出しに成功 |
| `make test-sync` | 実 Streams の登録・更新・論理／物理削除、停止時の退避、復旧と再投入、初回反映と再構築に成功。SAM で重複、逆順、削除後の再送、部分失敗と失敗レコードの再実行を確認 |
| `make test-iac` | Terraform 1.13.5 で整形チェック、バックエンドなしの初期化、静的検証、両 Provider をモックした3構成に成功 |
| `make up DB=aurora` と `python3 examples/bulk.py` | 登録の部分失敗（201／400）後、成功した商品を PUT、PATCH、DELETE で更新 |
| `DynamoAdmin bulk-demo`、`atomic-demo`、`gsi` | DynamoDB Local で一括の部分再試行、条件不一致でのロールバック、分類 GSI を確認 |
| `PostgresAdmin search`、`paging`、`atomic` | PostgreSQL で JOIN、ページ位置の一致、同時更新条件と全件ロールバックを確認 |
| `make benchmark`（短縮条件） | DynamoDB、PostgreSQL の6負荷条件、SQL 実行計画、Hybrid の遅延と復旧を測定 |
| `make benchmark-native`（短縮ビルド・測定条件） | Native Image の最終バイナリで3モードの CRUD、競合、ページングに成功。PostgreSQL 1,000件で JVM と Native を比較 |

初回検証で見つかった DynamoDB 永続ボリュームの所有権、ローカル SDK の環境プロキシ継承、最終ページでの `nextToken: null` の省略、Testcontainers の固定イメージ参照、SAM のコールドスタート時の待機時間と一時的な DB 接続失敗を修正しました。上記は修正後の結果です。

[AWS 向け構成](iac.md) の実環境におけるデプロイ、IAM、VPC 接続、証明書と DNS は未検証です。Cloudflare の実 API、AWS の実 API、GitHub Actions は使用していません。既存のバッチサンプルには差分がありません。性能の再現手順と実測は [性能測定](performance.md) を参照してください。
