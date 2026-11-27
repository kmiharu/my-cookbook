# 商品を登録・更新・検索する

Java 21 と Micronaut の商品マスタ API です。同じ CRUD を DynamoDB、Aurora PostgreSQL、Hybrid の構成で実行できます。Hybrid では DynamoDB の変更が Streams を経由して PostgreSQL の検索結果に反映されます。通常 HTTP と Lambda の入口は同じ API を処理します。

[OpenAPI](openapi/products.yaml) · [設計と DB の選び方](docs/design.md) · [同期](docs/sync.md) · [Terraform](docs/iac.md) · [派生例](docs/examples.md) · [性能測定](docs/performance.md) · [検証結果](docs/verification.md)

## ローカルで DB を選んで起動する

検証環境は Linux x86_64 です。Docker Engine と Docker Compose v2、Make、Bash、Python 3.11 以降、curl、unzip が必要です。Gradle は Wrapper を使います。Java 21 の JDK が手元にない環境ではローカルのツールディレクトリに固定版を取得します。SAM CLI、Terraform、GraalVM ベースの Native Image ツールも固定版を使います。初回は Maven リポジトリやコンテナレジストリなどの配布元に接続します。

```sh
cd api-sample
make up DB=dynamodb
```

| 試す構成 | コマンド | 起動する DB |
| --- | --- | --- |
| DynamoDB で登録・検索する | `make up DB=dynamodb` | DynamoDB Local |
| PostgreSQL だけで登録・検索する | `make up DB=aurora` | PostgreSQL |
| DynamoDB に登録して PostgreSQL で検索する | `make up DB=hybrid` | DynamoDB Local、PostgreSQL、同期ワーカー |

API は `http://127.0.0.1:8080` です。初期化では DynamoDB テーブルの作成または Flyway のマイグレーションをローカル DB に実行します。PostgreSQL のマイグレーションだけ再実行する場合は `make migrate DB=aurora` または `make migrate DB=hybrid` を実行します。別モードを試すときは起動中の構成を `make down` で終了してから新しいモードを起動してください。

## 商品を作って version 付きで変更する

```sh
base=http://127.0.0.1:8080
curl -i -X POST "$base/products" \
  -H 'Content-Type: application/json' -H 'X-Request-Id: demo-1' \
  -d '{"name":"ノート","category":"stationery","priceMinor":120,"status":"ACTIVE"}'

# 登録応答の id を指定します。
id="登録応答のID"
curl -i "$base/products/$id"
curl -i "$base/products?category=stationery&limit=5"
curl -i -X PATCH "$base/products/$id" -H 'Content-Type: application/json' \
  -H 'If-Match: "1"' -d '{"priceMinor":160}'
curl -i -X PUT "$base/products/$id" -H 'Content-Type: application/json' \
  -H 'If-Match: "2"' -d '{"name":"厚手ノート","category":"stationery","priceMinor":200,"status":"ACTIVE"}'
curl -i -X DELETE "$base/products/$id" -H 'If-Match: "3"'
```

登録は `201`、更新は `200`、削除は `204` です。別のリクエストが先に変更している場合は `412` が返るので、現在のデータを取得し直してください。DynamoDB と Hybrid の一覧は非同期に反映されます。一覧に続きがある場合は、同じ条件に応答の `nextToken` を追加します。

## PATCH の処理をコードで追う

1. `patch` は `If-Match` を version に変換し、指定された項目を検証します。 [ProductController.java](app/src/main/java/cookbook/api/ProductController.java)
2. `update` は現在の商品を取得し、省略された項目を引き継いで、次の version の商品を作ります。 [ProductService.java](app/src/main/java/cookbook/api/ProductService.java)
3. DB 側が version を照合して更新を確定します。DynamoDB の `replace` は条件付き `PutItem`、PostgreSQL の `replace` は `WHERE` 句の version 条件を使います。 [DynamoRepository.java](app/src/main/java/cookbook/api/db/DynamoRepository.java) · [PostgresStatements.xml](app/src/main/resources/cookbook/api/db/PostgresStatements.xml)

Hybrid では `ApplicationDatabase` が商品本体を DynamoDB に、一覧を PostgreSQL に割り当てます。反映処理を読むときは `ProductChanges.apply` から入り、SQL マッパーの `project` で version と削除状態を比較する条件を確認できます。 [ApplicationDatabase.java](app/src/main/java/cookbook/api/ApplicationDatabase.java) · [ProductChanges.java](app/src/main/java/cookbook/api/sync/ProductChanges.java)

## 通常 HTTP・Lambda・同期を検証する

```sh
make test
make test-e2e DB=dynamodb
make test-e2e DB=aurora
make test-e2e DB=hybrid
make test-lambda DB=dynamodb
make test-lambda DB=aurora
make test-lambda DB=hybrid
make test-sync
make test-iac
make verify
```

検証スクリプトは独立した Compose プロジェクトとデータを使用します。SAM CLI はローカルで `start-api` と `invoke` を実行し、Java 21 の Lambda イメージから同じローカル DB に接続します。手動で試す場合は `make sam-up DB=dynamodb` を起動し、API の URL を `http://127.0.0.1:3000` に変えます。REST API の入口は `SAM_API_TYPE=rest` を追加します。IaC の合否は整形チェック、バックエンドなしの初期化、静的バリデーションで確認します。GitHub Actions 用の定義は [テンプレート](ci/github-actions.yml.example) にあります。

性能測定は `make benchmark`、Native Image の比較は `make benchmark-native` で個別に実行します。条件、コマンド、計測結果は [性能測定](docs/performance.md) に記録します。

## ローカル構成を停止する

```sh
make down DB=dynamodb
# 確認用データも消す場合
make down DB=dynamodb CLEAN_VOLUMES=1
```

- Docker に接続できない場合は `docker info` と `docker compose version` でソケットと Compose を確認します。
- ポートが使用中の場合は、先に動作中の構成を終了します。初回の起動や SAM のコールドスタートには、依存物の取得やイメージの展開時間もかかります。
- `DATABASE_TYPE` や接続先の設定エラーが出た場合はモードを確認します。単独モードのアプリはもう一方の DB 設定を要求しません。
- Hybrid で単件は取得できるのに一覧に出ないときは、ワーカーのログと [同期の障害復旧手順](docs/sync.md) を確認します。

[AWS 向け Terraform 構成](docs/iac.md) の実デプロイは未検証です。性能値はローカルで使用したバージョンと条件に対する結果です。
