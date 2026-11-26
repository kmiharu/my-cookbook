$ErrorActionPreference = 'Continue'
$sqlFile = 'sql/export_csv.sql'
$outputDirectory = 'output'
$outputFile = 'output/customers.csv'

. (Join-Path $PSScriptRoot 'log.ps1')
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$previousClientEncoding = $env:PGCLIENTENCODING
$previousOutputEncoding = [Console]::OutputEncoding
$logPath = $null

try {
    $env:PGCLIENTENCODING = 'UTF8'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $logPath = New-OperationLog -Operation '04_export_csv'
    $targetDatabase = Get-TargetDatabase
    Write-Log -Level INFO -Message "開始  対象DB=$targetDatabase  SQL=$sqlFile  出力=$outputFile"

    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source
    $runName = [System.IO.Path]::GetFileNameWithoutExtension($logPath)
    $temporaryDirectory = "$outputDirectory/$runName"
    $temporaryFile = "$temporaryDirectory/customers.csv"

    Push-Location -LiteralPath $PSScriptRoot -ErrorAction Stop
    try {
        New-Item -Path $temporaryDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null

        # 一時ディレクトリで実行し、\copyの固定ファイル名に直接書き込む。
        Push-Location -LiteralPath $temporaryDirectory -ErrorAction Stop
        try {
            $psqlOutput = & $psql -X -w -q -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -f "../../$sqlFile" 2>&1
            $psqlExitCode = $LASTEXITCODE
            if ($psqlExitCode -ne 0) {
                $cause = Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlOutput
                throw "SQL=$sqlFile  psql終了コード=$psqlExitCode  原因=$cause"
            }
        } finally {
            Pop-Location
        }

        Move-Item -LiteralPath $temporaryFile -Destination $outputFile -Force -ErrorAction Stop
        Write-Log -Level INFO -Message "ファイル保存  出力=$outputFile"
    } finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Pop-Location
    }

    $elapsed = '{0:F3}' -f $stopwatch.Elapsed.TotalSeconds
    Write-Log -Level INFO -Message "正常終了  所要時間=${elapsed}秒"
    exit 0
} catch {
    if ($logPath) {
        $elapsed = '{0:F3}' -f $stopwatch.Elapsed.TotalSeconds
        Write-Log -Level ERROR -Message "異常終了  $($_.Exception.Message)  所要時間=${elapsed}秒"
    } else {
        [Console]::Error.WriteLine($_.Exception.Message)
    }
    exit 1
} finally {
    $env:PGCLIENTENCODING = $previousClientEncoding
    [Console]::OutputEncoding = $previousOutputEncoding
}
