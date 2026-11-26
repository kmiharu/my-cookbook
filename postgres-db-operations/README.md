| やりたいこと | 実行するファイル | 得られる結果 |
| --- | --- | --- |
| SQLの件数を変数に入れる | [01_count.ps1](./01_count.ps1) | `[long]` の `$totalCount` |
| PowerShellの変数をSQLに渡す | [02_limit_offset.ps1](./02_limit_offset.ps1) | 10件飛ばした後の5件のID |
| 同じSQLを繰り返し実行する | [03_loop.ps1](./03_loop.ps1) | 1,000件ずつ取得し、各回のOFFSETと件数を表示 |
| 検索結果を1つのCSVに保存する | [04_export_csv.ps1](./04_export_csv.ps1) | ヘッダー付きの `output/customers.csv` |
| 1カラムに格納されたJSONを取り出す | [05_export_json.ps1](./05_export_json.ps1) | JSON本文の表示、または `output/customer_42.json` |
| 期間を指定して分割CSVを保存する | [06_export_stdout.ps1](./06_export_stdout.ps1) | 実行ごとのフォルダに `customers_001.csv` から連番で保存 |
| CSVで指定した行だけを更新する | [07_csv_patch.ps1](./07_csv_patch.ps1) | 事前確認の結果と、反映した件数 |
| 対象IDを固定して1,000件ずつ更新する | [run_patch.bat](./run_patch.bat) / [run_patch.ps1](./run_patch.ps1) | バッチごとの実更新件数と未補正件数 |

## 練習用DBに接続してデータを入れる

Windows PowerShell 5.1 と、PATHから起動できる PostgreSQL 15 以降の `psql.exe` を使用します。練習DBも PostgreSQL 15 以降を使います。以下は `powershell.exe -NoProfile -ExecutionPolicy Bypass` で開いた練習用セッションで実行します。`$sample` はチェックアウト先に合わせて置き換えてください。以降は任意のカレントディレクトリから実行できます。

`cookbook_practice` はUTF-8の空の練習DBです。接続するユーザーにはこのDB内でスキーマを作成できる権限が必要です。パスワード認証には、必要に応じてリポジトリ外の [pgpass.conf](https://www.postgresql.org/docs/current/libpq-pgpass.html) を使います。

```powershell
$sample = 'C:\作業 フォルダー\my-cookbook\postgres-db-operations'
$env:PGHOST = 'localhost'
$env:PGPORT = '5432'
$env:PGDATABASE = 'cookbook_practice'
$env:PGUSER = 'cookbook_user'

$originalClientEncoding = $env:PGCLIENTENCODING
Push-Location -LiteralPath $sample -ErrorAction Stop
try {
    $env:PGCLIENTENCODING = 'UTF8'
    psql -X -w -v ON_ERROR_STOP=1 -f sql/setup.sql
    if ($LASTEXITCODE -ne 0) { throw '練習データの作成に失敗しました。' }
} finally {
    $env:PGCLIENTENCODING = $originalClientEncoding
    Pop-Location
}

& (Join-Path $sample '01_count.ps1')
```

[setup.sql](./sql/setup.sql) は接続先の `cookbook` スキーマを削除し、練習テーブルと作業テーブルを作り直します。専用の練習DBで実行してください。練習データにはID 1～2,501があり、ID 42の値とJSONにはカンマ、引用符、改行、絵文字が入っています。最初の `01_count.ps1` は `総件数=2501` を表示します。

スクリプトは一時的に `PGCLIENTENCODING` とコンソールの出力エンコーディングをUTF-8に設定し、終了時に戻します。事前の `chcp` は不要です。CSVと保存したJSONはUTF-8 BOMなしです。

## 件数と取得範囲を変える

```powershell
& (Join-Path $sample '02_limit_offset.ps1')
& (Join-Path $sample '03_loop.ps1')
```

02はID 11～15を1行ずつ表示します。`$batchSize` と `$offset` が [limit_offset.sql](./sql/limit_offset.sql) の `LIMIT` と `OFFSET` に入ります。03は同じSQLを使い、OFFSET 0、1000、2000で1,000件、1,000件、501件を取得します。01～03はデータを読み取るだけなので、セットアップ後に個別に実行できます。

## CSVとJSONを保存する

```powershell
& (Join-Path $sample '04_export_csv.ps1')
& (Join-Path $sample '05_export_json.ps1')
& (Join-Path $sample '05_export_json.ps1') -CustomerId 42 -Save
```

04は [export_csv.sql](./sql/export_csv.sql) の `\copy` でID、日付、値、補正状態を端末側の `output/customers.csv` に書き出します。psqlが行を直接ファイルに流すため、大きな抽出でもPowerShellに全件を保持しません。

05は既定でID 42の `payload` を標準出力に表示します。`-Save` を付けると、同じ [export_json.sql](./sql/export_json.sql) を実行した結果を `output/customer_42.json` に保存します。

```powershell
Get-Content -Raw -Encoding UTF8 (Join-Path $sample 'output/customer_42.json') |
    ConvertFrom-Json
```

## 期間を指定して抽出する

まず、1回分を標準出力で確認します。

```powershell
$originalClientEncoding = $env:PGCLIENTENCODING
$originalConsoleEncoding = [Console]::OutputEncoding
Push-Location -LiteralPath $sample -ErrorAction Stop
try {
    $env:PGCLIENTENCODING = 'UTF8'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    psql -X -w -q -v ON_ERROR_STOP=1 -v start_date=2026-01-01 -v end_date=2026-02-01 -v batch_size=5 -v batch_offset=0 -f sql/export_stdout.sql
    if ($LASTEXITCODE -ne 0) { throw '期間指定の抽出に失敗しました。' }
} finally {
    [Console]::OutputEncoding = $originalConsoleEncoding
    $env:PGCLIENTENCODING = $originalClientEncoding
    Pop-Location
}
```

全件を分割CSVに保存するには次を実行します。

```powershell
& (Join-Path $sample '06_export_stdout.ps1') -StartDate '2026-01-01' -EndDate '2026-02-01' -BatchSize 1000
```

件数取得と抽出はともに開始日以上、終了日未満で絞ります。一意なID順で1,000件、1,000件、500件になり、終了日ちょうどのID 2501は含まれません。`COPY ... TO STDOUT` の結果は `psql -o` で保存します。Windows版のpsqlが挿入した改行コードを戻し、項目内の改行を保ちます。OFFSETで分割する間は、対象行の追加、削除、条件や並び順に影響する更新がないことを前提にします。

## CSVの変更内容を確認してから反映する

配布用の [patch_input.sample.csv](./patch_input.sample.csv) を作業用の `patch_input.csv` にコピーします。必要なら作業用ファイルをUTF-8 BOMなしで編集します。列は `id,new_value` の順にします。空の `new_value` は空文字として取り込みます。

```powershell
Copy-Item -LiteralPath (Join-Path $sample 'patch_input.sample.csv') -Destination (Join-Path $sample 'patch_input.csv')
& (Join-Path $sample '07_csv_patch.ps1')
```

[preview.sql](./sql/preview.sql) は作業用CSVを `\copy ... FROM` で取り込みます。セットアップ直後は入力2件、DBに存在するIDが2件、値が変わる行が2件です。変更前後の値と確認IDが表示されます。確認だけならここで終了します。重複や存在しないIDがある場合は該当IDが表示されます。作業用CSVを直してからプレビューをやり直します。

反映する場合は、表示された確認IDを指定します。

```powershell
$reviewId = Read-Host '表示された確認IDを入力'
& (Join-Path $sample '07_csv_patch.ps1') -Mode Apply -ReviewId $reviewId
```

[apply.sql](./sql/apply.sql) はその確認IDで保存されたデータを使い、`UPDATE ... FROM` で値が変わる行だけを更新します。サンプルでは2件です。確認後に対象行が変わった場合は反映が停止するので、新しいプレビューで確認します。

## 対象を固定して1,000件ずつ更新する

通常実行と途中失敗からの再実行は、どちらも同じコマンドです。BATから練習用のPowerShellプロセスを起動します。

```powershell
& (Join-Path $sample 'run_patch.bat')
$LASTEXITCODE
```

[run_patch.ps1](./run_patch.ps1) は初回に未補正のIDを作業テーブルへ保存します。その一覧をID順で分割し、各バッチを1トランザクションで更新します。補正は `value` の先頭に `補正済み ` を付け、`corrected` を真にします。セットアップ直後の対象は2,501件で、実更新は1,000件、1,000件、501件です。最終確認の未補正件数は0です。

途中で失敗したら原因を取り除いて同じコマンドを実行します。固定した一覧の中で、補正済みの行は飛ばします。練習を最初からやり直す場合は、パッチを終了してから [setup.sql](./sql/setup.sql) を手動で再実行します。

## 実行ログを確認する

04～07と完成例は `logs/` に実行ごとのログをUTF-8で作ります。ファイル名に開始日時、処理名、プロセスIDが入り、07の確認と反映は別の処理名になります。進捗は標準エラーにも表示されます。失敗時はエラーの要旨を確認し、分割パッチでは最後にコミットが完了したバッチを確認できます。`output/` と `logs/` はこのREADMEと同じフォルダの下に作成されます。
