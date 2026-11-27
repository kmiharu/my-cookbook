$ErrorActionPreference = 'Stop'

$pageSql = 'sql/limit_offset.sql'
$batchSize = 5
$offset = 10

. (Join-Path $PSScriptRoot 'lib/psql.ps1')
$environment = Enter-PsqlEnvironment -Directory $PSScriptRoot
try {
    $psql = (Get-Command psql -CommandType Application).Source

    $ids = & $psql -X -w -qAt -v ON_ERROR_STOP=1 -v "batch_size=$batchSize" -v "batch_offset=$offset" -f $pageSql
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        throw "${pageSql} が失敗しました。psql終了コード=$psqlExitCode"
    }

    Write-Output $ids
} finally {
    Restore-PsqlEnvironment -State $environment
}
