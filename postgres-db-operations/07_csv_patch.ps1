param(
    [ValidateSet('Preview', 'Apply')]
    [string]$Mode = 'Preview',
    [string]$ReviewId
)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$modeName = $Mode.ToLowerInvariant()
$operation = "07_csv_patch_$modeName"
$sqlName = "$modeName.sql"
$sqlFile = "sql/$sqlName"
$inputName = 'patch_input.csv'
$inputPath = Join-Path $PSScriptRoot $inputName
$isPreview = $Mode -eq 'Preview'
$outputOptions = @('-A', '-t')
if ($isPreview) {
    $outputOptions = @('-P', 'pager=off')
}
$stateMessages = @{
    '22P04' = 'CSVの列名または形式が想定と異なります（22P04）'
    'P0701' = '重複IDまたはDBに存在しないIDがあります。画面のID一覧を確認してください。'
    'P0702' = '確認IDがありません。事前確認を実行してください。'
    'P0703' = '事前確認後に対象行が変わりました。事前確認からやり直してください。'
}

. (Join-Path $PSScriptRoot 'lib/psql.ps1')
. (Join-Path $PSScriptRoot 'lib/log.ps1')
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$environment = $null
$logPath = $null

try {
    $environment = Enter-PsqlEnvironment -Directory $PSScriptRoot
    $log = New-OperationLog -Directory (Join-Path $PSScriptRoot 'logs') -Operation $operation
    $logPath = $log.Path
    $targetDatabase = Get-TargetDatabase

    if ($isPreview) {
        $selectedReviewId = [Guid]::NewGuid()
        $condition = "入力=$inputName"
    } else {
        $selectedReviewId = [Guid]::Empty
        if (-not [Guid]::TryParse($ReviewId, [ref]$selectedReviewId)) {
            throw "SQL=$sqlName 原因=反映する確認IDを -ReviewId で指定してください。"
        }
        $condition = "確認ID=$selectedReviewId"
    }
    Write-Log -Path $logPath -Level INFO -Message "開始 DB=$targetDatabase SQL=$sqlName $condition"
    if ($isPreview -and -not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "SQL=$sqlName 原因=作業用CSVが見つかりません。保存先=$inputPath"
    }

    $psql = (Get-Command psql -CommandType Application -ErrorAction Stop).Source
    $psqlOutput = & $psql -X -w -q @outputOptions -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate `
        -v "review_id=$selectedReviewId" -f $sqlFile 2>&1
    $psqlExitCode = $LASTEXITCODE
    if ($psqlExitCode -ne 0) {
        if ($isPreview) {
            # 入力検証で止めた場合も、SQLが表示したIDの一覧を返す。
            $psqlOutput | Where-Object { $_ -is [string] }
        }
        throw (Format-PsqlFailure -SqlFile $sqlName -ExitCode $psqlExitCode -Messages $psqlOutput -StateMessages $stateMessages)
    }

    if ($isPreview) {
        $psqlOutput | Where-Object { $_ -is [string] }
        $completion = "事前確認完了 SQL=$sqlName 確認ID=$selectedReviewId"
    } else {
        $countError = "SQL=$sqlName psql終了コード=$psqlExitCode 原因=反映後の実更新件数を読み取れませんでした。"
        [long]$updatedCount = Read-PsqlCount -Output $psqlOutput -ErrorMessage $countError
        Write-Output $updatedCount
        $completion = "反映完了 SQL=$sqlName 確認ID=$selectedReviewId 実更新=$updatedCount 件"
    }
    Write-Log -Path $logPath -Level INFO -Message $completion
    Write-Log -Path $logPath -Level INFO -Message '正常終了' -Stopwatch $stopwatch
    exit 0
} catch {
    Write-Log -Path $logPath -Level ERROR -Message "異常終了 $($_.Exception.Message)" -Stopwatch $stopwatch
    exit 1
} finally {
    Restore-PsqlEnvironment -State $environment
}
