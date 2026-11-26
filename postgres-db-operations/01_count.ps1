$ErrorActionPreference = 'Stop'

$countSql = 'sql/count.sql'

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
    Write-Output "総件数=$totalCount"
} finally {
    $env:PGCLIENTENCODING = $originalClientEncoding
    [Console]::OutputEncoding = $originalConsoleEncoding
    Pop-Location
}
