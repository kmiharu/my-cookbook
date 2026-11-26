function Enter-PsqlEnvironment {
    param([string]$Directory)

    $state = [pscustomobject]@{
        Directory = (Get-Location).Path
        ClientEncoding = $env:PGCLIENTENCODING
        ConsoleEncoding = [Console]::OutputEncoding
    }
    try {
        $env:PGCLIENTENCODING = 'UTF8'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        Set-Location -LiteralPath $Directory -ErrorAction Stop
    } catch {
        Restore-PsqlEnvironment -State $state
        throw
    }
    return $state
}

function Restore-PsqlEnvironment {
    param($State)

    if ($null -eq $State) { return }
    try {
        Set-Location -LiteralPath $State.Directory -ErrorAction Stop
    } finally {
        $env:PGCLIENTENCODING = $State.ClientEncoding
        [Console]::OutputEncoding = $State.ConsoleEncoding
    }
}

function Get-TargetDatabase {
    $dbHost = $env:PGHOST
    if (-not $dbHost) { $dbHost = $env:PGHOSTADDR }
    if (-not $dbHost) { $dbHost = '(既定)' }
    $dbPort = $env:PGPORT
    if (-not $dbPort) { $dbPort = '(既定)' }
    $dbName = $env:PGDATABASE
    if (-not $dbName) { $dbName = '(既定)' }
    # 接続文字列には認証情報が含まれることがある。
    if ($dbName -match '[:=]') { $dbName = '(接続文字列)' }
    return "$dbHost ${dbPort}/$dbName"
}

function Read-PsqlCount {
    param([object[]]$Output, [string]$ErrorMessage)

    $rows = @($Output | Where-Object { $_ -is [string] })
    [long]$count = 0
    if ($rows.Count -ne 1 -or -not [long]::TryParse($rows[0], [ref]$count) -or $count -lt 0) {
        throw $ErrorMessage
    }
    return $count
}

function Format-PsqlFailure {
    param(
        [string]$SqlFile,
        [int]$ExitCode,
        [object[]]$Messages,
        [string]$Context,
        [hashtable]$StateMessages = @{}
    )

    # psqlが標準エラーへ最後に出したSQLSTATEを使い、エラー本文をログに渡さない。
    $sqlState = ''
    foreach ($message in $Messages) {
        if ($message -is [System.Management.Automation.ErrorRecord] -and
            [string]$message -cmatch ':\s+([0-9A-Z]{5})\s*$') {
            $sqlState = $Matches[1]
        }
    }
    if ($StateMessages.ContainsKey($sqlState)) {
        $cause = $StateMessages[$sqlState]
    } elseif ($sqlState) {
        $cause = switch ($sqlState) {
            '55P03' { 'ロックを取得できません（55P03）' }
            '57014' { 'SQLが取り消されました（57014）' }
            '22007' { '日付の形式が不正です（22007）' }
            '22008' { '日付が範囲外です（22008）' }
            '23502' { 'NOT NULL制約違反（23502）' }
            '23505' { '一意性制約違反（23505）' }
            '23514' { 'CHECK制約違反（23514）' }
            '22P02' { '入力値の形式が不正です（22P02）' }
            '40001' { '同時更新のため処理を継続できません（40001）' }
            '42P01' { 'テーブルが見つかりません（42P01）' }
            '42501' { '権限が不足しています（42501）' }
            'P0001' { 'SQLの事前条件を満たしていません（P0001）' }
            default { "SQLの処理に失敗しました（$sqlState）" }
        }
    } else {
        $cause = switch ($ExitCode) {
            1 { 'psqlがSQLファイルまたは入出力を処理できません' }
            2 { 'DBへの接続を確立または維持できません' }
            default { 'SQLまたはpsqlの処理に失敗しました' }
        }
    }
    $prefix = if ($Context) { "$Context  " }
    return "${prefix}SQL=$SqlFile  psql終了コード=$ExitCode  原因=$cause"
}
