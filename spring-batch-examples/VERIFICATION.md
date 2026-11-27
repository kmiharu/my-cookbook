# 実サービスで確認した出力・反映・再開

実行日 2026年11月27日。Linux x86_64、Java 21.0.13、Gradle 8.14.8、Docker Engine 29.9.2、Compose 2.40.3を使用した。PostgreSQL 16.15、SeaweedFS 4.55、DynamoDB Local 3.3.0を実際に起動した。Javaの計測は `-Xmx512m`。Dockerは4 GiB指定を受け付けたが、rootless daemonにcgroupコントローラーが委譲されず、コンテナ内の上限は共有の16 GiBだった。`systemd-run --user --scope` もユーザーバス不在で利用できなかった。以下のRSSはJavaプロセスの値で、分離されたコンテナmemory peakは取得できていない。

## 自動試験と少量シナリオを実行する

| 確認すること | 実行数 | 失敗・skip | 結果の確認先 |
| --- | ---: | --- | --- |
| CLI・設定とCSV/TSV/gzipの振る舞い | 11 | 0・0 | `batch-common/build/test-results/test/`、`batch-file/build/test-results/test/` |
| PostgreSQLの更新・COPY・ワークを照合する | 11 | 0・0 | `batch-examples/build/test-results/test/`。Testcontainersの実PostgreSQL |
| S3 multipart、固定版、片側の再開を照合する | 8 | 0・0 | `batch-storage/build/test-results/test/`。SeaweedFS 6件、境界ロジック2件 |
| DynamoDBの実操作と応答喪失を照合する | 7 | 0・0 | `batch-dynamodb/build/test-results/test/`。実Local 1件、SDK境界の試験6件 |
| AWS接続なしでTerraform定義を検査する | 8 | 0・0 | [Terraform検証ログ](./infra/verification.log)。加えて7構成でinit/validate、fmtも成功 |
| ECSの起動・待機・終了コードを検査する | 8 | 0・0 | [RunTaskスタブのログ](./infra/verification.log) |
| 標準・入出力・運用性能の27シナリオを実行する | 27 | 27件が最終確認で成功 | `scripts/verify-standard-scenarios.sh`、`bench-results/raw/standard-1795758404-117840/` |
| 業務更新・保守の14シナリオを実行する | 14 | 0・0 | `scripts/operations-scenarios.sh`。実行ログ `/workspace/scratch/operations-stable.log` |
| DynamoDBの8シナリオを実行する | 8 | 0・0 | `scripts/dynamodb-scenarios.sh`、`bench-results/raw/ddb-verify-c/` |

停止修正を含む最終JARで再度 `check :batch-examples:bootJar` が成功し、Gradleのテストは合計37件だった。外部サービス試験は `BATCH_S3_TEST_ENDPOINT=http://127.0.0.1:18333 BATCH_TEST_DYNAMO_ENDPOINT=http://127.0.0.1:18000 ./gradlew --max-workers=2 check :batch-examples:bootJar` で有効化した。少量シナリオは[カタログ](./SCENARIOS.md)の実行環境で照合した。 49件の内訳は[番号別の検証結果](./bench-results/scenarios-2026-11-27.tsv)に掲載。標準の確認中にディスク枯渇でSeaweedFSのPUTが失敗したため、空き容量を回復して未確認分を同じテスト用DB・固定JARで再試験した。 起動YAMLに未知の設定キーを渡した場合も、副作用前に終了コード2となり、値をログに出さないことを確認した。 最終イメージ `sha256:114da8df2c4ed30f9b2f490c668384c31766bdc68d315d775ac6839a3ca5fd06` でV6マイグレーション、2宛先の36行・953 Bのgzip、未知YAML設定の拒否を実行した。拒否時の対象runにはDB台帳もS3オブジェクトもなかった。 [最終イメージの記録](./bench-results/local-containers.md)

## 同じrunで停止後のデータを確認する

- S3の相手先Complete直後にJVMを停止し、旧実行がACTIVEの間に回復引数なしで起動すると拒否された。停止を確認後、同じJobInstanceでJobExecutionを追加して再開した。既存の相手先オブジェクトのversionIdを保持し、両バケットから取得したSHA-256が一致した。
- 到着待ちで旧プロセスが生存している間に同じrunを起動し、排他ロックで拒否されることを確認した。最初のプロセスは到着後に完了し、同じrunへ設定変更を渡した起動も拒否した。 `scripts/verify-run-ownership.sh`、`bench-results/raw/ownership-20261127T060655-202130/`。
- 入力のChunkコミット後にSIGKILLとJVMヒープOOMをそれぞれ起こした。停止時点のワークは有効1行、エラー1行で、業務表は0行だった。再開後は有効3行を1回だけ反映し、論理位置2のエラーが1行だけ残った。Dockerの `OOMKilled` はfalseだった。SIGTERMは `docker stop` で終了143となり、所有権はSTOPPEDで同じrunを再開できた。 [コンテナ検証のコマンドと結果](./bench-results/local-containers.md)
- DynamoDBの配送中に停止した初期試行では、トランザクションを外したTaskletがchecked例外を継続扱いし、旧実行がSTARTEDに残った。Batch 6の実装・スレッドダンプを確認し、全外部Taskletでchecked例外を終了へ伝播させ、協調停止時は `JobInterruptedException` に統一した。修正後は実DynamoDB Localへの低速配送でSIGTERMを受け、約1秒以内にSTOPPEDとなった。2/15件の確認位置から同じJobInstanceで再開し、15件を照合した。 `scripts/verify-restart-dynamodb.sh`、`bench-results/raw/ddb-signal-shared/`。
- 停止修正を検証したイメージ `sha256:8e4be862abe86fb81e51f949781fbbb233fab0fd98bbdf8264d173966674c2ab` では、非root起動、両バケットのgzip、入力検証と反映、DynamoDBの `docker stop` と再開、S3のComplete直後からの回復を実行した。Docker停止から約1秒でSTOPPEDとなり、同じJobInstanceで3件から15件まで反映した。 [最終イメージの結果](./bench-results/local-containers.md)
- 別PostgreSQLへの移行は、ターゲットのコミット直後・ソース進捗確定前に停止して再開した。ターゲットの進捗が1件から2件となり、二重適用なしを確認した。DynamoDBの加算もトランザクション成功直後に停止して再送し、残高3.375、version 1を確認した。 [DynamoDBの結果](./bench-results/dynamodb-local.md)

## 処理の責務を整理した版を再検証する

顧客Job、S3転送、DynamoDBのコードを整理した後のJARで、Gradleの37件（失敗・skip各0件）と、少量の実サービス試験49シナリオを再実行した。標準27件は `bench-results/raw/readability-standard/`、業務14件は `/workspace/scratch/batch-tools/readability-operations.log`、DynamoDB 8件は `bench-results/raw/ddb-readability-084728-438849/` に記録した。DynamoDB配送はSIGTERMで2件処理した時点から同じJobInstanceで再開し、15件を照合した。

## 負荷試験と性能の比較を確認する

| 確認する経路 | コンテナ時間 | 行/秒 | 格納・転送バイト | Java RSS高水位 | Java CPU / GC停止 |
| --- | ---: | ---: | ---: | ---: | --- |
| 100万行のgzipを2宛先へ出力 | 中央値44.161 s | 22,645 | 57,091,796 B、両宛先合計 | 中央値292.6 MiB | 20.43 s / 1.074 s |
| 100万行のgzipを取り込んでDBに反映 | 56.557 s | 17,681 | 8,613,577 B、入力 | 346.4 MiB | 28.52 s / 0.866 s |
| 1,000万行のgzipを2宛先へ出力 | 55.398 s | 180,511 | 576,284,166 B、両宛先合計 | 305.1 MiB | 51.54 s / 0.692 s |
| DynamoDBの100万件をQueryしてS3へ出力 | 163.062 s | 6,133 | 43,056,064 B、1宛先 | 370.9 MiB | 48.99 s / 1.063 s |

100万行の出力はウォームアップ1回と測定3回。各宛先の解凍後は80,977,814 B、格納は28,545,898 Bで圧縮比35.25%。取得・送信Stepは中央値26.518秒。最大GC直前heapは122 MiB。取込の指定行幅は256 Bで、最大GC直前heapは114 MiB。取込は1回で、全ID・値・NULLをDBで照合した。比較用のイメージ、行幅、サービス資源標本、生ログへの参照は[負荷試験の記録](./bench-results/local-2026-11-27.md)にある。

1,000万行は同じバッチイメージ、同じ指定行幅80 Bを使用し、出力の実幅は平均83.88 Bだった。出力Stepは51.181秒。最大GC直前heapは153 MiBだった。両宛先のSHA-256は `3dcc2d15a5db59cd8acbdfebee354393e8ab4040ff8d0837e9976f9242098bc4` で一致し、ID 1〜10,000,000を順番に読み、欠落と重複がないことを確認した。1,000万行は1回測定。Java RSS高水位は100万行試行の観測範囲281.2〜315.5 MiBに収まった。空き容量の制約により1,000万行の成功試行ではPostgreSQLとSeaweedFSの永続先をサービス側tmpfsにしたため、処理速度は100万行との倍率比較に使っていない。SeaweedFSに書込み可能なボリュームがなかった初回試行と、成功試行のデータ照合後にバケット削除が `BucketNotEmpty` を返した記録も残している。 [代表負荷試験の記録](./bench-results/local-2026-11-27.md)

DynamoDBの100万件はDynamoDB Local 3.3.0のインメモリー設定で1回測定した。Queryは1,001回でCountとScannedCountが各1,000,000、再試行0回。固定ワーク作成は146.104秒、S3出力は7.548秒、最大GC直前heapは153 MiB。入力準備のBatchWriteは40,001回、415.111秒で、計測対象から分けた。通常の永続SQLiteでの初回準備は46,400件で停止し、投入速度と停止問題を記録した。 [DynamoDB負荷試験の記録](./bench-results/dynamodb-local.md)

6,000行のSQL・索引・JDBC・COPY比較は、9条件でウォームアップ込み36試行が成功した。実測の中央値はSQLの条件式変更が7.966→4.322 ms、複合索引が0.626→0.132 ms、JDBC逐次/バッチ/rewriteが0.778/0.132/0.095秒。COPYは出力Stepと取込の主要Stepを短縮したが、起動や検証を含む全体時間は今回の条件で改善しなかった。初回計測器がシェルをサンプリングしていたため、この36試行のRSS・CPUは報告から除外した。修正後の計測器は独立したJavaプロセスで確認した。 [比較結果](./bench-results/database-6000.md) [実行計画JSON](./bench-results/database-6000-plans.json)

2万行・約1 KiBの比較はfetchSize、gzip、multipart、Partition、Chunkの15条件で、ウォームアップ込み60試行を照合した。別のPartition 1 Worker試行はS3 SDKのHTTP EOFで失敗し、別runで測定し直した。multipartは1宛先3パートで1→4 Workerにすると出力Step中央値が2.373→1.648秒。Partitionは1/2/4/8 Workerが1.835/1.573/1.441/2.359秒で、今回の8 Workerには改善がなかった。Chunkの100/1,000/2,000件はステージングの中央値が1.964/2.127/2.398秒で、コミット回数は200/20/10回。gzip level 9の追加削減はlevel 6から1,466 Bだった。10万行の約4 KiB幅試験も2宛先を照合し、9.304秒、10,747行/秒、Java RSS高水位358.4 MiBを観測した。 [2万行の比較結果](./bench-results/comparisons-2026-11-27.md) [10万行の測定結果](./bench-results/local-2026-11-27.md)

AWSアカウントへの接続と実デプロイは未実施。実ECS、実Aurora、IAM/KMS、クロスアカウント、実VPC通信、DynamoDBのスループットと費用、4 GiBで強制されたコンテナのOOMは未検証。
