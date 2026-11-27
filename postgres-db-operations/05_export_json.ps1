param(
    [long]$CustomerId = 42,
    [switch]$Save
)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$sqlFile = 'sql/export_json.sql'
$outputFile = "output/customer_$CustomerId.json"

. (Join-Path $PSScriptRoot 'lib/psql.ps1')
. (Join-Path $PSScriptRoot 'lib/log.ps1')
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$environment = $null
$log = @{ Path = $null }
$temporaryFile = $null

try {
    $environment = Enter-PsqlEnvironment -Directory $PSScriptRoot
    $log = New-OperationLog -Directory (Join-Path $PSScriptRoot 'logs') -Operation '05_export_json'
    $targetDatabase = Get-TargetDatabase
    $destination = if ($Save) { $outputFile } else { '標準出力' }
    Write-Log -Path $log.Path -Level INFO -Message "開始  対象DB=$targetDatabase  SQL=$sqlFile  ID=$CustomerId  出力=$destination"

    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source
    $outputOptions = @()
    if ($Save) {
        $null = New-Item -Path 'output' -ItemType Directory -Force -ErrorAction Stop
        $temporaryFile = "output/$($log.RunName).part"
        $outputOptions = @('-o', $temporaryFile)
    }

    $psqlOutput = & $psql -X -w -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -v "customer_id=$CustomerId" @outputOptions -f $sqlFile 2>&1
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        throw (Format-PsqlFailure -SqlFile $sqlFile -ExitCode $psqlExitCode -Messages $psqlOutput)
    }

    if ($Save) {
        $temporaryInfo = Get-Item -LiteralPath $temporaryFile -ErrorAction Stop
        if ($temporaryInfo.Length -eq 0) {
            throw "SQL=$sqlFile  原因=ID=$CustomerId のデータがありません。"
        }
        Move-Item -LiteralPath $temporaryFile -Destination $outputFile -Force -ErrorAction Stop
        Write-Log -Path $log.Path -Level INFO -Message "ファイル保存  出力=$outputFile"
    } else {
        $json = $psqlOutput | Where-Object { $_ -is [string] }
        if (-not $json) {
            throw "SQL=$sqlFile  原因=ID=$CustomerId のデータがありません。"
        }
        Write-Output $json
        Write-Log -Path $log.Path -Level INFO -Message "標準出力に表示  ID=$CustomerId"
    }

    Write-Log -Path $log.Path -Level INFO -Message '正常終了' -Stopwatch $stopwatch
    exit 0
} catch {
    Write-Log -Path $log.Path -Level ERROR -Message "異常終了  $($_.Exception.Message)" -Stopwatch $stopwatch
    exit 1
} finally {
    if ($temporaryFile) {
        Remove-Item -LiteralPath $temporaryFile -ErrorAction SilentlyContinue
    }
    Restore-PsqlEnvironment -State $environment
}
