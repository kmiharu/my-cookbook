# SQL・索引・JDBCとCOPYを6,000行で比較する

2026-11-27にローカルのPostgreSQL 16.15とSeaweedFS 4.55で計測しました。6,000件、seed 31、指定行幅256 B、顧客テーブルの実測平均行サイズ302.244 Bです。顧客IDは1〜6,000で、NULL、空文字、日本語、引用符内の改行を含めました。入力データのNULL率と空文字率はそれぞれ10%です。9条件をそれぞれ1回ウォームアップし、3回ずつ計測しました。検証を含む36試行すべてが成功しました。失敗とスキップは0件です。

Java 21.0.13のホストプロセスを `-Xmx512m` で実行しました。ホストの上位cgroupは4 CPU・16 GiBを共有します。この試行ではホスト計測器がシェルのPIDを参照していたため、RSSとプロセスCPUの値は集計から除外しました。ヒープの値はGCログで観測したGC直前使用量です。別に記録した4 GiBコンテナの負荷試験と資源条件が異なります。

修正後のサンプラーは、32 MiBの配列を保持する独立のJavaプロセスで動作確認しました。RSS高水位132,220 KiB、CPU 120 ticksを採取しました。これはサンプラーだけの結果です。観測ファイルは `raw/database-6000/host-sampler-spot/sampler-probe.samples.tsv` です。

```bash
./scripts/setup-local.sh
./gradlew :batch-examples:bootJar
BATCH_BENCH_HOST_JAR="$PWD/batch-examples/build/libs/batch-examples.jar" \
BATCH_BENCH_SERVICES_READY=1 \
./batch-test-support/compare-database-local.sh 6000 256 3 bench-results/raw/database-recheck
./batch-test-support/summarize-database.py bench-results/raw/database-recheck
```

実施時のJAR SHA-256は `4015f94d0578c86b9ccded2bfa01643266e1028ad0813a7fd776e84c5cf3a9cf` です。rawの `database-6000/` に `trials.tsv`、`environment.log`、`summary.json`、`diagnostics.json`、試行別のアプリログ、実行計画、Step、照合記録を保存しました。以下の表はウォームアップを除いた中央値と範囲です。

## 時刻範囲と複合索引の実行計画を比較する

| 変えた条件 | 実測行 | PostgreSQL実行時間 ms | 代表計画 |
| --- | ---: | ---: | --- |
| 列に日付関数を適用する | 6,000 | 7.966 (6.178–8.805) | Seq Scan → Sort |
| UTCの半開区間で絞る | 6,000 | 4.322 (2.796–19.044) | customer_pkey Index Scan |
| 状態・期間を複合索引なしで読む | 241 | 0.626 (0.504–0.681) | Seq Scan → Sort |
| 状態・期間を複合索引で読む | 241 | 0.132 (0.105–0.229) | Bitmap Index Scan → Bitmap Heap Scan → Sort |

日付範囲への変更で代表計画のSortがなくなりました。中央値は下がり、19.044 msの遅い試行もありました。複合索引では代表試行の共有バッファヒットが63から31に減り、メモリ上のSortは残りました。2比較の代表計画にディスク退避はありませんでした。[PostgreSQLの計画JSON](database-6000-plans.json)

## JDBCの実際のバッチ投入を比較する

| 投入方式 | 6,000件の投入とコミットの時間 秒 | 行/秒 |
| --- | ---: | ---: |
| prepared statementを逐次実行する | 0.778 (0.647–0.889) | 7,713 |
| executeBatchで送る | 0.132 (0.122–0.139) | 45,509 |
| 書換えを有効にしてexecuteBatchで送る | 0.095 (0.084–0.097) | 63,344 |

すべての方式で1,000行ごとにコミットし、投入先の件数を照合しました。JDBCバッチとドライバー書換えの両方で、投入とコミットの中央値が下がりました。

## Cursor／COPY出力とChunk／COPY取込を照合する

| 処理経路 | 主なStep 秒 | 起動から終了まで 秒 | 行/秒 | 観測heap MiB | GC pause合計 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cursor → 2宛先gzip | 1.524 (0.796–1.907) | 5.877 (4.600–7.331) | 1,021 | 87 | 149.8 |
| COPY → 2宛先gzip | 1.370 (0.792–1.514) | 6.150 (5.728–6.902) | 976 | 88 | 180.2 |
| gzip → Chunk → DB反映 | 0.513 (0.458–0.711) | 5.676 (4.650–6.258) | 1,057 | 88 | 106.7 |
| gzip → COPY → DB反映 | 0.378 (0.182–0.544) | 6.243 (5.210–9.382) | 961 | 88 | 147.5 |

両出力経路の各宛先で6,000行、展開後1,505,602 B、格納415,519 Bを観測しました。ウォームアップと3回の測定で、すべての格納SHA-256が `c67eb3241ec3aee6a5d01a3c0ad867cc6bbf811be3eb9b348c13c2b26e99d700` に一致しました。2宛先合計の成果物は831,038 Bです。両取込方式は同じ49,954 Bのgzipを使い、DBの全対象行でID、名前、NULL／空文字、状態、versionを照合しました。

COPYの主なStepの中央値は両比較で短くなりました。ジョブ全体の中央値はCursor／Chunkの経路より長く、出力も取込も測定範囲が重なりました。COPY取込のStepには固定入力の事前検証、2回目のS3読込、COPYとステージ確定が含まれます。このサイズの試行ではCOPYに切り替えた際の全体時間の改善を確認できませんでした。
