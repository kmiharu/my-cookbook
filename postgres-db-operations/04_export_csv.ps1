$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$sqlFile = 'sql/export_csv.sql'
$outputFile = 'output/customers.csv'

. (Join-Path $PSScriptRoot 'lib/psql.ps1')
. (Join-Path $PSScriptRoot 'lib/log.ps1')
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$environment = $null
$log = @{ Path = $null }
$temporaryDirectory = $null

try {
    $environment = Enter-PsqlEnvironment -Directory $PSScriptRoot
    $log = New-OperationLog -Directory (Join-Path $PSScriptRoot 'logs') -Operation '04_export_csv'
    $targetDatabase = Get-TargetDatabase
    Write-Log -Path $log.Path -Level INFO -Message "開始  対象DB=$targetDatabase  SQL=$sqlFile  出力=$outputFile"

    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source
    $temporaryDirectory = "output/$($log.RunName)"
    $null = New-Item -Path $temporaryDirectory -ItemType Directory -Force -ErrorAction Stop

    # 一時ディレクトリで実行し、\copyの固定ファイル名に直接書き込む。
    Push-Location -LiteralPath $temporaryDirectory -ErrorAction Stop
    try {
        $psqlOutput = & $psql -X -w -q -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -f "../../$sqlFile" 2>&1
        $psqlExitCode = $LASTEXITCODE
        if ($psqlExitCode -ne 0) {
            throw (Format-PsqlFailure -SqlFile $sqlFile -ExitCode $psqlExitCode -Messages $psqlOutput)
        }
    } finally {
        Pop-Location
    }

    Move-Item -LiteralPath "$temporaryDirectory/customers.csv" -Destination $outputFile -Force -ErrorAction Stop
    Write-Log -Path $log.Path -Level INFO -Message "ファイル保存  出力=$outputFile"
    Write-Log -Path $log.Path -Level INFO -Message '正常終了' -Stopwatch $stopwatch
    exit 0
} catch {
    Write-Log -Path $log.Path -Level ERROR -Message "異常終了  $($_.Exception.Message)" -Stopwatch $stopwatch
    exit 1
} finally {
    if ($temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    Restore-PsqlEnvironment -State $environment
}
