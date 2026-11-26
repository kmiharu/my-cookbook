param(
    [long]$CustomerId = 42,
    [switch]$Save
)

$ErrorActionPreference = 'Continue'
$sqlFile = 'sql/export_json.sql'
$outputDirectory = 'output'
$outputFile = "$outputDirectory/customer_$CustomerId.json"

. (Join-Path $PSScriptRoot 'log.ps1')
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$previousClientEncoding = $env:PGCLIENTENCODING
$previousOutputEncoding = [Console]::OutputEncoding
$logPath = $null
$temporaryFile = $null

try {
    $env:PGCLIENTENCODING = 'UTF8'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $logPath = New-OperationLog -Operation '05_export_json'
    $targetDatabase = Get-TargetDatabase
    $destination = '標準出力'
    if ($Save) {
        $destination = $outputFile
    }
    Write-Log -Level INFO -Message "開始  対象DB=$targetDatabase  SQL=$sqlFile  ID=$CustomerId  出力=$destination"

    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source
    Push-Location -LiteralPath $PSScriptRoot -ErrorAction Stop
    try {
        $outputOptions = @()
        if ($Save) {
            New-Item -Path $outputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            $runName = [System.IO.Path]::GetFileNameWithoutExtension($logPath)
            $temporaryFile = "$outputDirectory/$runName.part"
            $outputOptions = @('-o', $temporaryFile)
        }

        $psqlOutput = & $psql -X -w -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -v "customer_id=$CustomerId" @outputOptions -f $sqlFile 2>&1
        $psqlExitCode = $LASTEXITCODE
        if ($psqlExitCode -ne 0) {
            $cause = Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlOutput
            throw "SQL=$sqlFile  psql終了コード=$psqlExitCode  原因=$cause"
        }

        if ($Save) {
            $temporaryInfo = Get-Item -LiteralPath $temporaryFile -ErrorAction Stop
            if ($temporaryInfo.Length -eq 0) {
                throw "SQL=$sqlFile  原因=ID=$CustomerId のデータがありません。"
            }
            Move-Item -LiteralPath $temporaryFile -Destination $outputFile -Force -ErrorAction Stop
            Write-Log -Level INFO -Message "ファイル保存  出力=$outputFile"
        } else {
            $json = $psqlOutput | Where-Object { $_ -is [string] }
            if (-not $json) {
                throw "SQL=$sqlFile  原因=ID=$CustomerId のデータがありません。"
            }
            Write-Output $json
            Write-Log -Level INFO -Message "標準出力に表示  ID=$CustomerId"
        }
    } finally {
        if ($temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -ErrorAction SilentlyContinue
        }
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
