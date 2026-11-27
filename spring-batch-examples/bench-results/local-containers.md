# ローカルの実サービスで停止と再開を確認する

2026-11-27、Linux x86_64、Docker Engine 29.9.2、Compose 2.40.3、Temurin 21.0.13で実行した。PostgreSQL 16.15、SeaweedFS 4.55、DynamoDB Local 3.3.0をComposeで起動した。使用したCLIはAWS CLI 2.42.4。

| できること | 実行したコマンド | 確認できた結果 |
| --- | --- | --- |
| PostgreSQLに接続し、S3バケットとDynamoDBのキーを準備する | `./scripts/setup-local.sh` | 本体と移行先の両方にSQLで接続した。3バケットでversioningを有効化し、DynamoDBのPK/SK、GSI、操作IDキーを照合した。 |
| multipartを確定・中止し、上書き前の入力を読む | `./scripts/probe-local-s3.sh` | 5 MiBと22 Bの2パートを作成・送信・確定した。HEADとGETで内容・メタデータ・版を照合した。上書き前のETagによるGETと既存オブジェクトへの条件付きCompleteは412で拒否された。指定した旧版をGETでき、Abort後に一覧からアップロードが消えた。 |
| DynamoDBの空ページを続けて読み、同じ加算を二重に実行しない | `./scripts/probe-local-dynamodb.sh` | Queryの空ページにLastEvaluatedKeyが返り、次ページを取得した。GSI QueryとScanを実行した。条件付き加算と処理済み記録を同じトランザクションで確定し、同じ要求を再送してもversion 2、残高3.5のままだった。 |
| Dockerで2バケットに出力し、gzipをPostgreSQLへ取り込む | `BATCH_USE_EXISTING_IMAGE=1 ./scripts/verify-local.sh` | 非rootのJavaがPID 1で動作した。両宛先の11行、671 B、SHA-256 `8c34d631201ee9b0b9d56888faf4fb0dea0ad9ed5c7a653b2705eb749545adf3` が一致した。日本語と引用符内の改行を含む入力2件をDBで照合した。未知の起動引数で終了コード2だった。 |
| Complete直後に停止した出力を同じrunで確定する | `./scripts/verify-restart-s3.sh` | partnerへのComplete直後にJVMを終了コード97で停止した。旧所有者の回復指定を欠いた起動は拒否された。JobInstance 24でExecution 25をFAILEDに回復し、Execution 29がCOMPLETEDになった。partnerの版 `67142fce26978780da3272a3e666baae` は回復前後で一致し、両宛先の格納バイトも同じSHA-256だった。 |
| 到着待ちをSIGTERMで止める | `./scripts/verify-stop-local.sh` | `docker stop`後に終了コード143、run台帳はSTOPPEDだった。ファイル到着後に同じrunで起動し、COMPLETEDになった。 |
| Chunkコミット後のSIGKILLとJVMのOOMから再開する | `BATCH_IMAGE=spring-batch-examples:verified ./scripts/verify-chunk-recovery.sh` | `docker kill --signal KILL`で終了コード137を取得した。ヒープ上限を超える割り当てを行う別試行では `OutOfMemoryError: Java heap space` が記録され、終了コード3だった。両試行ともDockerの`OOMKilled`はfalseだった。再開前はワーク1行、エラー1行、業務反映0行だった。再開後は有効3行を適用し論理位置2のエラーが1行だけ残った。JobInstance 41のExecutionは44から48、JobInstance 48のExecutionは52から54へ進んだ。 |
| 移行先の空のPostgreSQLを準備する | `docker compose --profile batch run --rm -T --no-deps -e "BATCH_TARGET_DB_URL=jdbc:postgresql://postgres-target:5432/$target_database" batch job=Migrate runId=verified-image-fresh-target` | 移行先に専用の履歴表が作成され、バージョン1の成功をSQLで確認した。修正前のイメージがすでに別のDDLを適用した既定DBは維持し、試験用に別DBを作成した。 |

生ログは次の作業ディレクトリに保存した。`bench-results/raw/`はGitの管理対象外であり、表のコマンドで再生成できる。

- `raw/complete-crash-20261127T053606-56348/`
- `raw/stop-arrival-20261127T053736-56341/`
- `raw/chunk-loss-20261127T053916-77095/`

## 実行イメージと資源制限を照合する

- 通常の`docker compose --profile batch build batch`は、この実行環境ではJavaからのGradleダウンロードが`ConnectException`になった。ビルド段階だけに実行環境がDockerへ注入したプロキシとJavaの信頼ストアをBuildKit secretで提供し、Gradle Wrapperを使うマルチステージビルドを通した。そのイメージIDは `sha256:fd5519407920bcebb1485109573101813c7c44d47eff3bdcabdf4d00e03136a9`。
- 追加したChunk故障試験では、ホストでビルドした新しいBoot JARを同じランタイム段階へ格納した。この試験に使ったイメージIDは `sha256:f00b6df283be70ba7a3fe3bc1c2f80e58ff382fa63606e2cc4a2bd9b3ba0dd60`。両イメージのJava起動引数とUID 10001をDockerで確認した。本番イメージの定義はリポジトリのDockerfileに置く。
- `docker run --rm --memory 4g --entrypoint sh spring-batch-examples:local -ec 'cat /sys/fs/cgroup/memory.max'` の実測は `17179869184` Bだった。このrootless Dockerでは設定した4 GiBを強制できなかった。`systemd-run --user --scope -p MemoryMax=4G /usr/bin/true` はユーザー用scopeバスがないため失敗した。JVMは各試行で`-Xmx512m`とした。コンテナのメモリ制限によるOOMと実AWSでの実行は未検証。

## V6を含む最終スナップショットで実行する

最終の `check :batch-examples:bootJar` が成功した時点のJARを、同じDockerfileのランタイム段階へ格納した。JARのSHA-256は `508efc13c48d31fe115bae5ba0cde832d664d9d6dde7c8d610f0e96efd3941e8`。`spring-batch-examples:verified-final` のイメージIDは `sha256:687148f2f6a7f2bd3b089ee2bbd0d060d589f7ff29c66d49bf15ee91fae482aa`。`raw/final-local-image/image-build.log` と `raw/final-local-image/verify-local.log` に記録した。

```bash
docker compose exec -T postgres-target createdb -U cookbook verified_final_target
BATCH_TARGET_DB_NAME=verified_final_target BATCH_IMAGE=spring-batch-examples:verified-final \
  BATCH_USE_EXISTING_IMAGE=1 ./scripts/verify-local.sh
```

V6の本体マイグレーションと、空の別DBに対する移行先V1の適用が成功した。2宛先で32行、各926 Bのgzipを照合した。それぞれのmanifestに両宛先の成果物が登録され、行数、SHA-256、versionIdを確認した。両宛先のSHA-256は `6124c6e6c6cf1dd6b86fcdc6fa02c75d76c6c515b24c331ff4b034122d85d0d3`。取込2行、未知の引数の終了コード2、実行UID 10001を再確認した。4 GiB指定時の観測値は引き続き16 GiBだった。

同じ最終イメージで `BATCH_IMAGE=spring-batch-examples:verified-final ./scripts/verify-restart-s3.sh` を再実行した。JobInstance 70のExecution 76がFAILEDとなり、Execution 77がCOMPLETEDになった。partnerのversionId `67142e93fc88580c26fc13695033e238` は回復前後で同じだった。両宛先の格納SHA-256は `3edd84b6c08a1dc2e12b6a56706b18693ba755f312dbe057ad5318b2691b62be` だった。生ログは `raw/final-local-image/restart-s3/` にある。

## SeaweedFSのボリューム数を調整する

共有のSeaweedFSを使った1,000万行試行の初回は、書き込み可能なボリュームを割り当てられず失敗した。Composeでは`BATCH_S3_VOLUME_MAX`を指定できる。既定値の`0`では、SeaweedFSがデータディスクの空き容量とボリュームサイズから個数を決める。個数を指定するときは、専用の練習環境で `docker compose exec -T s3 df -h /data` を実行し、使用可能な実容量を確認する。設定値の変更はSeaweedFSの再起動を伴う。 [SeaweedFS 4.55のmini実装](https://github.com/seaweedfs/seaweedfs/blob/4.55/weed/command/mini.go)

## Taskletの停止修正を含むイメージで実行する

`JobTasklets.class`を含むBoot JARのSHA-256は `4876ca09560dd96992238c6d1d3807b4b7fb9e39db7ffccfb7662ed9b47d309b`。ローカルで使用した `spring-batch-examples:verified-stopfix` のイメージIDは `sha256:8e4be862abe86fb81e51f949781fbbb233fab0fd98bbdf8264d173966674c2ab`。同じTemurin・CAバンドル・UID 10001・Java起動設定を持つ実行イメージに、このJARを格納した。コンテナ内のJARとCAバンドルのSHA-256を照合した。

`BATCH_TARGET_DB_NAME=verified_final_target BATCH_IMAGE=spring-batch-examples:verified-stopfix BATCH_USE_EXISTING_IMAGE=1 ./scripts/verify-local.sh` が成功した。両宛先に34行・各940 Bのgzipとmanifestを出力し、格納SHA-256 `3edd84b6c08a1dc2e12b6a56706b18693ba755f312dbe057ad5318b2691b62be` を照合した。gzip入力2行を反映し、不正引数で終了コード2だった。生ログは `raw/stopfix-local-image/` に保存した。

- `./scripts/verify-restart-dynamodb.sh` を同じイメージで実行した。`docker stop`から1秒でコンテナは終了コード143になった。DynamoDBへ配送済みの3件で停止し、JobInstance 78のExecution 87がSTOPPED、再開したExecution 88がCOMPLETEDになった。最終的な15件が各1回、version 0で存在することをDynamoDB Localへの整合性読み取りで照合した。生ログは `raw/stopfix-local-image/restart-dynamodb/` にある。
- `./scripts/verify-restart-s3.sh` を同じイメージで実行した。Complete後に停止し、JobInstance 79のExecution 89をFAILEDに回復した。新しいExecution 90がCOMPLETEDになった。両宛先の格納SHA-256 `db0adf77c7d747b93be36bed37f4c5484cd5a4083841cef8bdb45c0f905e8735` と、partnerの回復前後のversionId `67142daa0a68cfd5e1befa15fa9169b6` が一致した。生ログは `raw/stopfix-local-image/restart-s3/` にある。

## YAMLの未登録オプションを起動時に拒否する

YAMLのオプション名もCLIと同じ許可リストで検証するJARを、停止修正を確認したランタイムへ格納した。`spring-batch-examples:verified-release` のイメージIDは `sha256:114da8df2c4ed30f9b2f490c668384c31766bdc68d315d775ac6839a3ca5fd06`。コンテナから計算したJARのSHA-256は `b493ab9b281b79dea3bb59f53267e8f275dfcf173cd50a76e803a95b835940f2` で、ビルド成果物と一致した。CAバンドルの固定SHA-256も照合した。

このイメージで本体V6と移行先V1を確認し、`WorkTableExport`で36行・各953 Bを2宛先へ送った。格納バイト列を両宛先からストリーム取得し、SHA-256 `db0adf77c7d747b93be36bed37f4c5484cd5a4083841cef8bdb45c0f905e8735` を照合した。模擬値を含む未登録名 `fake.password` をYAMLへ入れた別実行は終了コード2だった。模擬値がログに現れず、そのrunのPostgreSQL台帳と両宛先のS3に記録がないことを確認した。SeaweedFSの空一覧では`KeyCount`が省略されたため、`Contents`も確認した。生ログは `raw/release-local-image/` にある。SIGTERMとComplete後の停止に関する結果は、上記の停止修正を含むイメージで確認した。
