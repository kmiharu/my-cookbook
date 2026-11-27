# 顧客を条件付きで更新・復元する

## 変更を確認してから適用する

`DataPatch` の既定動作はプレビューです。対象の顧客ID、現在値、予定値、versionを `batch_patch_row` に固定します。 `batch_patch_plan` に件数とMapper XMLの定義ハッシュを記録します。CSVはプレビューの固定行から生成します。

```bash
docker compose --profile batch run --rm batch job=DataPatch runId=patch-preview-001 \
  patchId=status-001 planId=review-001 sql.status=INACTIVE targetStatus=ACTIVE maxRows=1000

docker compose --profile batch run --rm batch job=DataPatchApply runId=patch-apply-001 \
  patchId=status-001 planId=review-001 expectedRows=3 maxRows=1000

docker compose --profile batch run --rm batch job=DataPatchRestore runId=patch-restore-001 \
  patchId=status-001 planId=review-001 expectedRows=3 maxRows=1000
```

上の適用・復元コマンドの `expectedRows=3` は、確認したプレビューの実件数に置き換えます。 `patchId` は適用時の一意キーです。適用・復元の `runId` は実行ごとに作ります。同じ実行を再開するときは元の `runId` と引数を使います。

既定の `mode=single` では、計画の取得、更新、監査行へのバージョン記録、件数確認、状態確定を一つのPostgreSQLトランザクションで行います。実更新のWHERE句はプレビュー時の値とversionに一致する行を対象にします。Restoreでは適用時の値とversionを照合し、業務列の `status` を戻して新しいversionと更新時刻を記録します。

`mode=chunk chunkSize=1000` では、計画を `APPLYING` または `RESTORING` にしてから固定キー順に処理します。対象列の更新、変更後versionとCheckpointはChunkごとに確定します。後続のChunkで競合が起きたときも、コミット済みChunkは残ります。競合は対象行と監査行を比較して解消します。競合が継続する間は実行が失敗したままです。パッチIDの記録を操作して再適用できる状態にする運用は対象外です。

S3のバックアップと差分は確定済み監査行から生成します。S3障害後の同じrunは出力Stepから続けます。

## 移行先のCheckpointを確認する

`DataMigration` は、元DBで対象値を通常ワークへ固定し、別PostgreSQLへChunk単位で送ります。移行先の `customer` と `batch_migration_progress` に一つのターゲットDBトランザクションで書きます。結果が一致する既存行はそのままにし、異なる既存行は競合とします。

`job=Migrate` に管理用DBユーザーと `BATCH_TARGET_DB_URL`、`BATCH_TARGET_DB_USER`、`BATCH_TARGET_DB_PASSWORD` を渡して、専用の移行先DBにもFlywayのDDLを適用します。通常の `DataMigration` に渡すターゲットユーザーには必要なSELECTとINSERTを付与します。

ターゲットのコミット直後にプロセスが停止したときは、元DBのChunkを再読します。確定済みのキーは移行先の進捗から判定します。元DBと移行先をまたぐトランザクションは設けず、移行先で再適用を防ぎます。

## 完全な入力で同期し、古いワークを整理する

- `CustomerDelete` の入力ヘッダは `id,version` です。入力版の照合と全体検証の後に顧客を削除します。実更新では現在のversion、固定した値、影響件数を照合します。
- `MasterSync` の既定動作は新規と変更行の反映です。入力にない顧客も削除するときは、完全な入力を準備し、`input.rows`、`input.sha256`、`deleteMissing=true` を指定します。入力を末尾まで検証し、エラーがなく全行がワークに入ったことを確認してから、固定した変更差分を一つのDBトランザクションで反映します。
- `DataArchive` は顧客行の固定、S3保存、成果物の照合を行います。その後に固定値とversionが一致した顧客を削除します。削除済みの印を同じトランザクションで記録するため、DB確定後に停止しても削除を二重に行いません。退避CSVの対象は顧客列です。会員がいる顧客は、準備時と実削除時の両方で検出し、実行を止めます。
- `DataCleanup` は、`COMPLETED` かつ `retainDays` を過ぎたrunの入出力、業務、COPY、DynamoDBのワークを削除します。実行メタデータ、パッチ監査、入力エラー、成果物台帳、配送台帳は調査に使えるよう保持します。
- `IncrementalExport` は `watermarkId` ごとに時刻を管理します。前回上限から `overlapSeconds` を引いた時刻と実行時に固定した上限の間を出力します。成功したmanifestの後で上限を進めます。受信側では顧客IDとversionで冪等に反映します。時刻の重複期間に入りきらない遅延コミットも扱う用途では、別途CDCを検討します。

`scripts/operations-scenarios.sh` は専用の名前でローカルの元・先PostgreSQLにそれぞれデータベースを作り、各シナリオのDBとS3成果物を確認します。移行の試験では対象Chunkのターゲット確定直後にテスト専用設定で停止し、同じrunを再開します。
