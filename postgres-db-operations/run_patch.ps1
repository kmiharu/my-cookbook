$batchSize = 1000
$psqlOptions = @('-X', '-w', '-qAt', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=sqlstate')

# Windows PowerShell 5.1でpsqlの標準エラーを受け取り、終了コードで失敗を判定する。
$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'lib/psql.ps1')
. (Join-Path $PSScriptRoot 'lib/log.ps1')

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$environment = $null
$logPath = $null
$exitCode = 1
$batchCount = 0
$completedBatches = 0
[long]$totalUpdated = 0

try {
    $environment = Enter-PsqlEnvironment -Directory $PSScriptRoot
    $log = New-OperationLog -Directory (Join-Path $PSScriptRoot 'logs') -Operation 'run_patch'
    $logPath = $log.Path
    $targetDatabase = Get-TargetDatabase
    Write-Log -Path $logPath -Level INFO -Message "開始  対象DB=$targetDatabase  バッチサイズ=$batchSize"
    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source

    # 初回に対象IDを固定する。再実行でも同じ一覧を使う。
    $sqlFile = '01_fix_patch_targets.sql'
    $psqlOutput = & $psql @psqlOptions -f "sql/$sqlFile" 2>&1
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        $exitCode = $psqlExitCode
        throw (Format-PsqlFailure -SqlFile $sqlFile -ExitCode $psqlExitCode -Messages $psqlOutput)
    }

    # 固定一覧の件数を取得する。
    $sqlFile = '02_count_patch_targets.sql'
    $psqlOutput = & $psql @psqlOptions -f "sql/$sqlFile" 2>&1
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        $exitCode = $psqlExitCode
        throw (Format-PsqlFailure -SqlFile $sqlFile -ExitCode $psqlExitCode -Messages $psqlOutput)
    }
    [long]$totalCount = Read-PsqlCount -Output $psqlOutput -ErrorMessage "SQL=$sqlFile  psql終了コード=$psqlExitCode  原因=対象件数を読み取れませんでした。"
    $batchCount = [long][Math]::Ceiling([decimal]$totalCount / $batchSize)
    Write-Log -Path $logPath -Level INFO -Message "対象確定  対象=${totalCount}件  バッチサイズ=$batchSize"

    # 固定一覧を1,000件ずつ更新する。終了コード0でコミット完了を確認する。
    $sqlFile = '03_patch_batch.sql'
    for ([long]$offset = 0; $offset -lt $totalCount; $offset += $batchSize) {
        $batchNumber = $completedBatches + 1
        $batchLabel = "バッチ $batchNumber/$batchCount"
        $psqlOutput = & $psql @psqlOptions --single-transaction `
            -v "batch_size=$batchSize" -v "batch_offset=$offset" -f "sql/$sqlFile" 2>&1
        $psqlExitCode = $LASTEXITCODE
        if ($psqlExitCode -ne 0) {
            $exitCode = $psqlExitCode
            $context = "$batchLabel 失敗  OFFSET=$offset"
            throw (Format-PsqlFailure -SqlFile $sqlFile -ExitCode $psqlExitCode -Messages $psqlOutput -Context $context)
        }

        $completedBatches = $batchNumber
        $countError = "$batchLabel コミット済み  OFFSET=$offset  SQL=$sqlFile  psql終了コード=$psqlExitCode  原因=実更新件数を読み取れませんでした。"
        [long]$updatedCount = Read-PsqlCount -Output $psqlOutput -ErrorMessage $countError
        $totalUpdated += $updatedCount
        Write-Log -Path $logPath -Level INFO -Message "$batchLabel 完了  OFFSET=$offset  更新=${updatedCount}件"
    }

    # 固定一覧の全行が補正済みなら正常終了する。
    $sqlFile = '04_check_patch_remaining.sql'
    $psqlOutput = & $psql @psqlOptions -f "sql/$sqlFile" 2>&1
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        $exitCode = $psqlExitCode
        throw (Format-PsqlFailure -SqlFile $sqlFile -ExitCode $psqlExitCode -Messages $psqlOutput)
    }
    [long]$remainingCount = Read-PsqlCount -Output $psqlOutput -ErrorMessage "SQL=$sqlFile  psql終了コード=$psqlExitCode  原因=未補正件数を読み取れませんでした。"
    if ($remainingCount -ne 0) {
        throw "SQL=$sqlFile  psql終了コード=$psqlExitCode  原因=未補正の対象が ${remainingCount}件あります。"
    }

    $summary = "正常終了  対象=${totalCount}件  今回更新=${totalUpdated}件  残件=${remainingCount}件"
    Write-Log -Path $logPath -Level INFO -Message $summary -Stopwatch $stopwatch
} catch {
    Write-Log -Path $logPath -Level ERROR -Message $_.Exception.Message
    Write-Log -Path $logPath -Level ERROR -Message "異常終了  最後に完了したバッチ=$completedBatches/$batchCount" -Stopwatch $stopwatch
    exit $exitCode
} finally {
    Restore-PsqlEnvironment -State $environment
}
exit 0
