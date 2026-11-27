# CRUD の派生例を実行する

## 一括処理で項目ごとの成否を確認する

`make up DB=dynamodb`、`DB=aurora`、`DB=hybrid` のいずれかで起動し、以下を実行します。

```sh
python3 examples/bulk.py <<'JSON'
{"operation":"create","product":{"name":"ノート","category":"stationery","priceMinor":120,"status":"ACTIVE"}}
{"operation":"create","product":{"name":"鉛筆","category":"stationery","priceMinor":-1,"status":"ACTIVE"}}
JSON
```

1行目は `201`、2行目は `400` です。処理結果は入力順に表示され、どれかが失敗すると終了コード1を返します。成功分は確定します。次の実行では結果に含まれた ID と version を使い、同じ形式で `replace`（全項目）、`patch`（変更項目）、`delete`（product なし）を指定できます。

```json
{"operation":"patch","id":"<登録応答のid>","version":1,"product":{"priceMinor":150}}
{"operation":"delete","id":"<登録応答のid>","version":2}
```

`412` の項目を再実行する場合は version を取得し直します。接続断で登録結果が不明な場合、無条件で再送すると別 ID の商品が作られます。DynamoDB の専用一時テーブルで `BatchWriteItem` の未処理項目だけを再送する例も実行できます。DynamoDB Local で再送を確認するため、初回送信では1件を保留させます。実際の書き込みはローカル DB へ送ります。バッチの置き換えと物理削除には CRUD の version 条件がありません。専用データに対して実行します。

```sh
./scripts/local.sh exec dynamodb cookbook.api.db.DynamoAdmin bulk-demo
./scripts/local.sh exec dynamodb cookbook.api.db.DynamoAdmin atomic-demo
./scripts/local.sh exec dynamodb cookbook.api.db.DynamoAdmin gsi stationery 10
```

`atomic-demo` はいずれかの version が古いとバッチ全体を取り消し、すべて一致すると全件更新することを確認します。PostgreSQL の同じトランザクション特性と JOIN、ページング比較は [PostgreSQL の派生例](postgres.md) を参照してください。

## 物理削除を Streams 経由で反映する

Hybrid で登録済み商品の ID と最新 version を指定します。物理削除後も削除マーカーが残り、古い同期レコードを再投入しても復活しません。詳しい再同期と障害復旧は [同期手順](sync.md) を参照してください。

```sh
./scripts/local.sh exec hybrid cookbook.api.db.DynamoAdmin purge "$id" "$version"
```

## REST API の v1 イベントを処理する

`make test-lambda DB=dynamodb` で HTTP API 2.0 の CRUD と REST API 1.0 の `sam local invoke` を試せます。Lambda の入口とイベントは [sam/](../sam/) にあります。
