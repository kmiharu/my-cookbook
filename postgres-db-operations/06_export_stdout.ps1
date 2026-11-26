param(
    [ValidatePattern('\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z')]
    [string]$StartDate = '2026-01-01',

    [ValidatePattern('\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z')]
    [string]$EndDate = '2026-02-01',

    [ValidateRange(1, 2147483647)]
    [int]$BatchSize = 1000
)

$ErrorActionPreference = 'Continue'
$countSql = 'sql/count_period.sql'
$exportSql = 'sql/export_stdout.sql'

function Restore-CsvNewlines {
    param(
        [string]$SourceFile,
        [string]$DestinationFile
    )

    # COPY TO STDOUTはレコードをLFで区切る。Windows版のpsql -oが
    # ヘッダーをCRLFで書いた場合は、各LFの直前に追加されたCRを1個ずつ除く。
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $buffer = [char[]]::new(8192)
    $reader = [System.IO.StreamReader]::new($SourceFile, $utf8)
    try {
        $readCount = $reader.ReadBlock($buffer, 0, $buffer.Length)
        $chunk = [string]::new($buffer, 0, $readCount)
        $headerEnd = $chunk.IndexOf([char]10)
        if ($headerEnd -lt 1 -or $chunk[$headerEnd - 1] -ne [char]13) {
            return $false
        }

        $writer = [System.IO.StreamWriter]::new($DestinationFile, $false, $utf8)
        try {
            $pending = ''
            while ($chunk.Length -gt 0) {
                $chunk = $pending + $chunk
                $pending = ''
                if ($chunk[$chunk.Length - 1] -eq [char]13) {
                    # CRとLFが別の読み取りに分かれても変換できるようにする。
                    $pending = "`r"
                    $chunk = $chunk.Substring(0, $chunk.Length - 1)
                }
                $writer.Write($chunk.Replace("`r`n", "`n"))
                $readCount = $reader.ReadBlock($buffer, 0, $buffer.Length)
                $chunk = [string]::new($buffer, 0, $readCount)
            }
            $writer.Write($pending)
        } finally {
            $writer.Dispose()
        }
    } finally {
        $reader.Dispose()
    }
    return $true
}

. (Join-Path $PSScriptRoot 'log.ps1')
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$previousClientEncoding = $env:PGCLIENTENCODING
$previousOutputEncoding = [Console]::OutputEncoding
$logPath = $null
$completedBatches = 0
$batchCount = 0

try {
    $env:PGCLIENTENCODING = 'UTF8'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $logPath = New-OperationLog -Operation '06_export_stdout'
    $targetDatabase = Get-TargetDatabase
    $runName = [System.IO.Path]::GetFileNameWithoutExtension($logPath)
    $outputDirectory = "output/$runName"
    Write-Log -Level INFO -Message "開始  対象DB=$targetDatabase  開始日=$StartDate  終了日=$EndDate（含まない）  バッチサイズ=$BatchSize  出力=$outputDirectory"

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $start = [datetime]::ParseExact($StartDate, 'yyyy-MM-dd', $culture)
    $end = [datetime]::ParseExact($EndDate, 'yyyy-MM-dd', $culture)
    if ($start -ge $end) {
        throw '開始日には終了日より前の日付を指定してください。'
    }

    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source
    Push-Location -LiteralPath $PSScriptRoot -ErrorAction Stop
    try {
        $psqlOutput = & $psql -X -w -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -v "start_date=$StartDate" -v "end_date=$EndDate" -f $countSql 2>&1
        $psqlExitCode = $LASTEXITCODE
        if ($psqlExitCode -ne 0) {
            $cause = Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlOutput
            throw "SQL=$countSql  psql終了コード=$psqlExitCode  原因=$cause"
        }

        $countResult = $psqlOutput | Where-Object { $_ -is [string] }
        [long]$totalCount = 0
        if (-not [long]::TryParse($countResult, [ref]$totalCount)) {
            throw "SQL=$countSql  原因=抽出件数を数値に変換できません。"
        }

        $batchCount = [long][Math]::Ceiling([decimal]$totalCount / $BatchSize)
        Write-Log -Level INFO -Message "対象件数=$totalCount  ファイル数=$batchCount"
        if ($totalCount -gt 0) {
            New-Item -Path $outputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $batchNumber = 1
        for ([long]$offset = 0; $offset -lt $totalCount; $offset += $BatchSize) {
            $fileName = 'customers_{0:D3}.csv' -f $batchNumber
            $outputFile = "$outputDirectory/$fileName"
            $temporaryFile = "$outputFile.part"
            $normalizedFile = "$outputFile.normalized.part"
            try {
                $psqlOutput = & $psql -X -w -q -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -v "start_date=$StartDate" -v "end_date=$EndDate" -v "batch_size=$BatchSize" -v "batch_offset=$offset" -o $temporaryFile -f $exportSql 2>&1
                $psqlExitCode = $LASTEXITCODE
                if ($psqlExitCode -ne 0) {
                    $cause = Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlOutput
                    throw "バッチ $batchNumber/$batchCount 失敗  OFFSET=$offset  SQL=$exportSql  psql終了コード=$psqlExitCode  原因=$cause"
                }

                $sourcePath = Join-Path $PSScriptRoot $temporaryFile
                $normalizedPath = Join-Path $PSScriptRoot $normalizedFile
                $readyFile = $temporaryFile
                if (Restore-CsvNewlines -SourceFile $sourcePath -DestinationFile $normalizedPath) {
                    $readyFile = $normalizedFile
                }
                Move-Item -LiteralPath $readyFile -Destination $outputFile -ErrorAction Stop
                $completedBatches = $batchNumber
                Write-Log -Level INFO -Message "バッチ $batchNumber/$batchCount 完了  OFFSET=$offset  出力=$outputFile"
            } finally {
                Remove-Item -LiteralPath $temporaryFile, $normalizedFile -ErrorAction SilentlyContinue
            }
            $batchNumber += 1
        }
    } finally {
        Pop-Location
    }

    $elapsed = '{0:F3}' -f $stopwatch.Elapsed.TotalSeconds
    Write-Log -Level INFO -Message "正常終了  ファイル数=$completedBatches  所要時間=${elapsed}秒"
    exit 0
} catch {
    if ($logPath) {
        $elapsed = '{0:F3}' -f $stopwatch.Elapsed.TotalSeconds
        Write-Log -Level ERROR -Message "異常終了  最後に保存したバッチ=$completedBatches/$batchCount  $($_.Exception.Message)  所要時間=${elapsed}秒"
    } else {
        [Console]::Error.WriteLine($_.Exception.Message)
    }
    exit 1
} finally {
    $env:PGCLIENTENCODING = $previousClientEncoding
    [Console]::OutputEncoding = $previousOutputEncoding
}
