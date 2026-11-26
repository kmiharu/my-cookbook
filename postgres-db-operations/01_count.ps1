$ErrorActionPreference = 'Stop'

$countSql = 'sql/count.sql'

. (Join-Path $PSScriptRoot 'lib/psql.ps1')
$environment = Enter-PsqlEnvironment -Directory $PSScriptRoot
try {
    $psql = (Get-Command psql -CommandType Application).Source

    $countResult = & $psql -X -w -qAt -v ON_ERROR_STOP=1 -f $countSql
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        throw "${countSql} が失敗しました。psql終了コード=$psqlExitCode"
    }

    $totalCount = [long]::Parse($countResult)
    Write-Output "総件数=$totalCount"
} finally {
    Restore-PsqlEnvironment -State $environment
}
