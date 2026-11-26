$ErrorActionPreference = 'Stop'

$countSql = 'sql/count.sql'
$pageSql = 'sql/limit_offset.sql'
$batchSize = 1000

$originalClientEncoding = $env:PGCLIENTENCODING
$originalConsoleEncoding = [Console]::OutputEncoding
Push-Location -LiteralPath $PSScriptRoot -ErrorAction Stop
try {
    $env:PGCLIENTENCODING = 'UTF8'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psql = (Get-Command psql -CommandType Application).Source

    $countResult = & $psql -X -w -qAt -v ON_ERROR_STOP=1 -f $countSql
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        throw "${countSql} が失敗しました。psql終了コード=$psqlExitCode"
    }

    $totalCount = [long]::Parse($countResult)

    for ($offset = 0L; $offset -lt $totalCount; $offset += $batchSize) {
        $ids = & $psql -X -w -qAt -v ON_ERROR_STOP=1 -v "batch_size=$batchSize" -v "batch_offset=$offset" -f $pageSql
        $psqlExitCode = $LASTEXITCODE
        if ($psqlExitCode -ne 0) {
            throw "${pageSql} が失敗しました。OFFSET=$offset psql終了コード=$psqlExitCode"
        }

        $pageCount = @($ids).Count
        Write-Output "OFFSET=$offset 取得=$pageCount 件"
    }
} finally {
    $env:PGCLIENTENCODING = $originalClientEncoding
    [Console]::OutputEncoding = $originalConsoleEncoding
    Pop-Location
}
