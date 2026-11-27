# PostgreSQL で商品を検索・更新する

`make up DB=aurora` で PostgreSQL と API を起動します。既存のスキーマを更新する場合は `make migrate DB=aurora` を使います。Flyway が適用済みのバージョンを記録するため、同じマイグレーションを再実行できます。

## 分類マスタを結合して絞り込む

たとえば `category=books`、`status=ACTIVE`、`priceMinor=1200` の商品を API で登録します。次の CLI は books の販売中の商品を最小価格で絞り込み、分類マスタの表示名を返します。

```sh
./scripts/local.sh exec aurora cookbook.api.db.PostgresAdmin search books ACTIVE 1000 20
```

共通 API は分類の完全一致で検索します。この例は PostgreSQL 側の比較演算と `LEFT JOIN` を追加します。分類マスタにない分類コードは格納でき、該当コードの表示名は空になります。

## OFFSET とキーセットで同じページを取得する

10件以上の商品を登録してから実行すると、先頭5件を除いた位置から最大5件の ID を両方式で表示します。

```sh
./scripts/local.sh exec aurora cookbook.api.db.PostgresAdmin paging 5 5
```

比較用 CLI は、先行行の作成日時と ID を OFFSET で取得してキーセットの境界にします。API は前ページの最終行から境界を得ます。固定データなら両方式の ID が一致します。途中で行が追加・削除された場合、OFFSET は開始位置がずれることがあります。キーセットにも複数リクエストをまたぐスナップショット保証はありません。

## 2件の更新を同じトランザクションで確定する

異なる商品を2件登録し、応答に含まれる ID と version を使います。

```sh
./scripts/local.sh exec aurora cookbook.api.db.PostgresAdmin atomic "$FIRST_ID" 1 1200 "$SECOND_ID" 1 1800
```

両方の version が一致した場合、両商品の価格が変わり version が増えます。2件目に古い version を渡した場合は非ゼロで終了し、1件目の変更もロールバックします。SQL は商品 ID と version を条件に更新します。
