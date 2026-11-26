param(
    [ValidateSet('Preview', 'Apply')]
    [string]$Mode = 'Preview',
    [string]$ReviewId
)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$operation = "07_csv_patch_$($Mode.ToLowerInvariant())"
if ($Mode -eq 'Preview') {
    $sqlFile = 'sql/preview.sql'
    $outputOptions = @('-P', 'pager=off')
} else {
    $sqlFile = 'sql/apply.sql'
    $outputOptions = @('-A', '-t')
}

. (Join-Path $PSScriptRoot 'log.ps1')
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$previousClientEncoding = $env:PGCLIENTENCODING
$previousConsoleEncoding = [Console]::OutputEncoding
$logPath = $null

try {
    $env:PGCLIENTENCODING = 'UTF8'
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $logPath = New-OperationLog -Operation $operation
    $targetDatabase = Get-TargetDatabase
    $sqlName = Split-Path -Leaf $sqlFile

    if ($Mode -eq 'Preview') {
        $selectedReviewId = [Guid]::NewGuid()
        Write-Log -Level INFO -Message "開始 DB=$targetDatabase SQL=$sqlName 入力=patch_input.csv"
        $inputPath = Join-Path $PSScriptRoot 'patch_input.csv'
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "SQL=$sqlName 原因=作業用CSVが見つかりません。保存先=$inputPath"
        }
    } else {
        $selectedReviewId = [Guid]::Empty
        if (-not [Guid]::TryParse($ReviewId, [ref]$selectedReviewId)) {
            throw "SQL=$sqlName 原因=反映する確認IDを -ReviewId で指定してください。"
        }
        Write-Log -Level INFO -Message "開始 DB=$targetDatabase SQL=$sqlName 確認ID=$selectedReviewId"
    }

    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source
    Push-Location -LiteralPath $PSScriptRoot -ErrorAction Stop
    try {
        $psqlOutput = & $psql -X -w -q @outputOptions -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate `
            -v "review_id=$selectedReviewId" -f $sqlFile 2>&1
        $psqlExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $psqlResult = @($psqlOutput | Where-Object { $_ -is [string] })
    if ($Mode -eq 'Preview') {
        # 入力検証で止めた場合も、SQLが表示したIDの一覧を返す。
        Write-Output $psqlResult
    }

    if ($psqlExitCode -ne 0) {
        $psqlMessages = @($psqlOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        switch -Regex ($psqlMessages -join "`n") {
            '\b22P04\b' {
                $cause = 'CSVの列名または形式が想定と異なります（22P04）'
                break
            }
            '\bP0701\b' {
                $cause = '重複IDまたはDBに存在しないIDがあります。画面のID一覧を確認してください。'
                break
            }
            '\bP0702\b' {
                $cause = '確認IDがありません。事前確認を実行してください。'
                break
            }
            '\bP0703\b' {
                $cause = '事前確認後に対象行が変わりました。事前確認からやり直してください。'
                break
            }
            default {
                $cause = Get-PsqlFailureCause -ExitCode $psqlExitCode -Messages $psqlMessages
            }
        }
        throw "SQL=$sqlName psql終了コード=$psqlExitCode 原因=$cause"
    }

    if ($Mode -eq 'Preview') {
        Write-Log -Level INFO -Message "事前確認完了 SQL=$sqlName 確認ID=$selectedReviewId"
    } else {
        [long]$updatedCount = 0
        if ($psqlResult.Count -ne 1 -or -not [long]::TryParse($psqlResult[0], [ref]$updatedCount)) {
            throw "SQL=$sqlName psql終了コード=$psqlExitCode 原因=反映後の実更新件数を読み取れませんでした。"
        }
        Write-Output $updatedCount
        Write-Log -Level INFO -Message "反映完了 SQL=$sqlName 確認ID=$selectedReviewId 実更新=$updatedCount 件"
    }

    Write-Log -Level INFO -Message "正常終了 所要時間=$([Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)) 秒"
    exit 0
} catch {
    if ($logPath) {
        $elapsed = '{0:F3}' -f $stopwatch.Elapsed.TotalSeconds
        Write-Log -Level ERROR -Message "異常終了 $($_.Exception.Message) 所要時間=${elapsed}秒"
    } else {
        [Console]::Error.WriteLine($_.Exception.Message)
    }
    exit 1
} finally {
    [Console]::OutputEncoding = $previousConsoleEncoding
    $env:PGCLIENTENCODING = $previousClientEncoding
}
