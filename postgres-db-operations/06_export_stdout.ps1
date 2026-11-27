param(
    [ValidatePattern('\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z')]
    [string]$StartDate = '2026-01-01',

    [ValidatePattern('\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z')]
    [string]$EndDate = '2026-02-01',

    [ValidateRange(1, 2147483647)]
    [int]$BatchSize = 1000
)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$countSql = 'sql/count_period.sql'
$exportSql = 'sql/export_stdout.sql'

. (Join-Path $PSScriptRoot 'lib/psql.ps1')
. (Join-Path $PSScriptRoot 'lib/log.ps1')
. (Join-Path $PSScriptRoot 'lib/csv-output.ps1')
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$environment = $null
$log = @{ Path = $null }
$completedBatches = 0
$batchCount = 0

try {
    $environment = Enter-PsqlEnvironment -Directory $PSScriptRoot
    $log = New-OperationLog -Directory (Join-Path $PSScriptRoot 'logs') -Operation '06_export_stdout'
    $targetDatabase = Get-TargetDatabase
    $outputDirectory = "output/$($log.RunName)"
    Write-Log -Path $log.Path -Level INFO -Message "開始  対象DB=$targetDatabase  開始日=$StartDate  終了日=$EndDate（含まない）  バッチサイズ=$BatchSize  出力=$outputDirectory"

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $start = [datetime]::ParseExact($StartDate, 'yyyy-MM-dd', $culture)
    $end = [datetime]::ParseExact($EndDate, 'yyyy-MM-dd', $culture)
    if ($start -ge $end) {
        throw '開始日には終了日より前の日付を指定してください。'
    }

    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source
    $periodOptions = @('-v', "start_date=$StartDate", '-v', "end_date=$EndDate")
    $psqlOutput = & $psql -X -w -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate @periodOptions -f $countSql 2>&1
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        throw (Format-PsqlFailure -SqlFile $countSql -ExitCode $psqlExitCode -Messages $psqlOutput)
    }

    $totalCount = Read-PsqlCount -Output $psqlOutput -ErrorMessage "SQL=$countSql  原因=抽出件数を数値に変換できません。"
    $batchCount = [long][Math]::Ceiling([decimal]$totalCount / $BatchSize)
    Write-Log -Path $log.Path -Level INFO -Message "対象件数=$totalCount  ファイル数=$batchCount"
    if ($totalCount -gt 0) {
        $null = New-Item -Path $outputDirectory -ItemType Directory -Force -ErrorAction Stop
    }

    for ([long]$offset = 0; $offset -lt $totalCount; $offset += $BatchSize) {
        $batchNumber = $completedBatches + 1
        $fileName = 'customers_{0:D3}.csv' -f $batchNumber
        $outputFile = "$outputDirectory/$fileName"
        $temporaryFile = "$outputFile.part"
        try {
            $psqlOutput = & $psql -X -w -q -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate @periodOptions `
                -v "batch_size=$BatchSize" -v "batch_offset=$offset" -o $temporaryFile -f $exportSql 2>&1
            $psqlExitCode = $LASTEXITCODE
            if ($psqlExitCode -ne 0) {
                $context = "バッチ $batchNumber/$batchCount 失敗  OFFSET=$offset"
                throw (Format-PsqlFailure -SqlFile $exportSql -ExitCode $psqlExitCode -Messages $psqlOutput -Context $context)
            }

            $sourcePath = Join-Path $PSScriptRoot $temporaryFile
            $destinationPath = Join-Path $PSScriptRoot $outputFile
            Save-CopyCsv -SourceFile $sourcePath -DestinationFile $destinationPath
            $completedBatches = $batchNumber
            Write-Log -Path $log.Path -Level INFO -Message "バッチ $batchNumber/$batchCount 完了  OFFSET=$offset  出力=$outputFile"
        } finally {
            Remove-Item -LiteralPath $temporaryFile -ErrorAction SilentlyContinue
        }
    }

    Write-Log -Path $log.Path -Level INFO -Message "正常終了  ファイル数=$completedBatches" -Stopwatch $stopwatch
    exit 0
} catch {
    Write-Log -Path $log.Path -Level ERROR -Message "異常終了  最後に保存したバッチ=$completedBatches/$batchCount  $($_.Exception.Message)" -Stopwatch $stopwatch
    exit 1
} finally {
    Restore-PsqlEnvironment -State $environment
}
