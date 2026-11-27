# 実装・検証の記録

| 確認すること | 実装と検証 |
| --- | --- |
| リポジトリを選び、依存を固定する | 既存の `kmiharu/my-cookbook` を取得。基点は `225a16c`。初期ZIPはローカルとリポジトリに見つからなかったため新規実装。Gradle Wrapper、BOM、Dockerイメージdigest、Terraformのlockfileを管理。 |
| 2宛先へ配布し、受信ファイルを検証・反映する | 逐次Cursor、CSV/TSV、gzip、S3台帳、固定入力、Chunkと論理位置、READY、条件付き反映を実装。少量の両宛先出力とgzip入力をComposeで確認。 |
| 業務更新・保守を行う | 業務Job、固定ワーク、パッチの監査と復元、別DB移行、退避と整理を実装。業務の結合試験は使い捨てDBで実行。 |
| DynamoDBと連携する | Query/Scan、条件付き操作、永続操作ID、outboxを実装。DynamoDB LocalとSDK境界の故障注入を分けて集計。 |
| SQL・COPY・圧縮・並列度を比較する | 計測ハーネス、設定別Job、実行計画とストリーム照合を実装。実測済み条件と実行できなかった条件は検証記録に掲載。 |
| 同じイメージでECS起動契約を確認する | ローカルコンテナ、非root、終了と再開、Terraform、RunTaskスタブを検証。AWSへの作成・変更は未実施。 |
| 全シナリオの準備から結果照合まで再現する | [シナリオ一覧](./SCENARIOS.md)、[実行手順](./README.md)、[再開の契約](./DESIGN.md)、[結果記録](./VERIFICATION.md)。 |

実行中に修正した点は、SpringのRepositoryプロキシとfinalクラスの競合、並列StepのBatch台帳のトランザクション分離レベル、Batch 6のTaskletでchecked例外が継続扱いになった停止処理、ローカルDockerのプロキシ設定、DynamoDB Localの永続ディレクトリ所有者です。検証環境のDockerは4 GiBの要求を受け付けましたが、有効なcgroup上限は共有の16 GiBでした。
