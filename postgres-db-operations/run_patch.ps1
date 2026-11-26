$ErrorActionPreference = 'Stop'
$batchSize = 1000
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$previousEncoding = [Console]::OutputEncoding
$previousClientEncoding = $env:PGCLIENTENCODING
$locationChanged = $false
$logPath = $null
$sqlFile = $null
$psqlExitCode = $null
$step = '準備'
$offsetDetail = ''
$batchCount = 0
$completedBatches = 0
[long] $totalUpdated = 0

. (Join-Path $PSScriptRoot 'log.ps1')

function Get-ResultCount {
    param([object[]] $PsqlOutput)

    $countLines = @($PsqlOutput -match '^[0-9]+$')
    [long] $count = 0
    if ($countLines.Count -ne 1 -or -not [long]::TryParse($countLines[0], [ref] $count)) {
        throw 'psqlの出力から件数を取得できませんでした。'
    }
    return $count
}

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $env:PGCLIENTENCODING = 'UTF8'

    $logPath = New-OperationLog -Operation 'run_patch'
    $targetDatabase = Get-TargetDatabase
    Write-Log -Level INFO -Message "開始  対象DB=$targetDatabase  バッチサイズ=$batchSize"

    $null = Get-Command psql -CommandType Application -ErrorAction Stop
    Push-Location -LiteralPath $PSScriptRoot
    $locationChanged = $true

    # 対象IDを固定する。初回に保存した一覧を次回も使う。
    $step = '対象IDの固定'
    $sqlFile = '01_fix_patch_targets.sql'
    $psqlOutput = & {
        # Windows PowerShell 5.1で標準エラーを受け取り、終了コードを先に確認する。
        $ErrorActionPreference = 'Continue'
        & psql -X -w -q -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -f "sql/$sqlFile" 2>&1
    }
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        throw (Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlOutput)
    }

    # 固定一覧の件数を取得する。
    $step = '対象件数の取得'
    $sqlFile = '02_count_patch_targets.sql'
    $psqlExitCode = $null
    $psqlOutput = & {
        $ErrorActionPreference = 'Continue'
        & psql -X -w -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -f "sql/$sqlFile" 2>&1
    }
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        throw (Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlOutput)
    }
    [long] $totalCount = Get-ResultCount -PsqlOutput $psqlOutput
    [long] $batchCount = [Math]::Ceiling($totalCount / [double] $batchSize)
    Write-Log -Level INFO -Message "対象確定  対象=${totalCount}件  バッチサイズ=$batchSize"

    # 固定一覧を1,000件ずつ更新する。psqlの終了コード0を確認してから完了を記録する。
    $sqlFile = '03_patch_batch.sql'
    for ([long] $offset = 0; $offset -lt $totalCount; $offset += $batchSize) {
        $batchNumber = $completedBatches + 1
        $step = "バッチ $batchNumber/$batchCount"
        $offsetDetail = "  OFFSET=$offset"
        $psqlExitCode = $null
        $psqlOutput = & {
            $ErrorActionPreference = 'Continue'
            & psql -X -w -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate --single-transaction `
                -v "batch_size=$batchSize" -v "batch_offset=$offset" -f "sql/$sqlFile" 2>&1
        }
        $psqlExitCode = $LASTEXITCODE
        if ($psqlExitCode -ne 0) {
            throw (Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlOutput)
        }

        [long] $updatedCount = Get-ResultCount -PsqlOutput $psqlOutput
        $totalUpdated += $updatedCount
        $completedBatches = $batchNumber
        Write-Log -Level INFO -Message "$step 完了  OFFSET=$offset  更新=${updatedCount}件"
    }

    # 固定一覧の全行が補正済みなら正常終了する。
    $step = '残件確認'
    $offsetDetail = ''
    $sqlFile = '04_check_patch_remaining.sql'
    $psqlExitCode = $null
    $psqlOutput = & {
        $ErrorActionPreference = 'Continue'
        & psql -X -w -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate -f "sql/$sqlFile" 2>&1
    }
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        throw (Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlOutput)
    }
    [long] $remainingCount = Get-ResultCount -PsqlOutput $psqlOutput
    if ($remainingCount -ne 0) {
        throw "未補正の対象が ${remainingCount}件あります。"
    }

    $seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    Write-Log -Level INFO -Message "正常終了  対象=${totalCount}件  今回更新=${totalUpdated}件  残件=${remainingCount}件  所要時間=${seconds}秒"
}
catch {
    $cause = $_.Exception.Message
    if ($null -eq $logPath) {
        [Console]::Error.WriteLine($cause)
    }
    else {
        $details = $offsetDetail
        if ($null -ne $sqlFile) {
            $details += "  SQL=$sqlFile"
        }
        if ($null -ne $psqlExitCode) {
            $details += "  psql終了コード=$psqlExitCode"
        }

        try {
            Write-Log -Level ERROR -Message "$step 失敗${details}  原因=$cause"
            $seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            Write-Log -Level ERROR -Message "異常終了  最後に完了したバッチ=$completedBatches/$batchCount  所要時間=${seconds}秒"
        }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
        }
    }

    if ($null -ne $psqlExitCode -and $psqlExitCode -ne 0) {
        exit $psqlExitCode
    }
    exit 1
}
finally {
    if ($locationChanged) {
        Pop-Location
    }
    $env:PGCLIENTENCODING = $previousClientEncoding
    [Console]::OutputEncoding = $previousEncoding
}
exit 0
