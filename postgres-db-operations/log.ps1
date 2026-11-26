function New-OperationLog {
    param([string]$Operation)

    $logDirectory = Join-Path $PSScriptRoot 'logs'
    $startedAt = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $path = Join-Path $logDirectory "${startedAt}_${Operation}_${PID}.log"
    try {
        $null = [System.IO.Directory]::CreateDirectory($logDirectory)
        $file = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew)
        $file.Dispose()
    } catch {
        throw "ログを作成できません。保存先=$path 理由=$($_.Exception.Message)"
    }

    return $path
}

function Write-Log {
    param(
        [ValidateSet('INFO', 'ERROR')][string]$Level,
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $singleLine = $Message -replace '[\r\n]+', ' '
    $line = "$timestamp [$Level] $singleLine"
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, $utf8)
    [Console]::Error.WriteLine($line)
}

function Get-TargetDatabase {
    $dbHost = $env:PGHOST
    if (-not $dbHost) { $dbHost = $env:PGHOSTADDR }
    if (-not $dbHost) { $dbHost = '(既定)' }
    $dbPort = $env:PGPORT
    if (-not $dbPort) { $dbPort = '(既定)' }
    $dbName = $env:PGDATABASE
    if (-not $dbName) { $dbName = '(既定)' }
    # 接続文字列の形式で渡された値は認証情報を含むことがある。
    if ($dbName -match '[:=]') { $dbName = '(接続文字列)' }

    return "$dbHost ${dbPort}/$dbName"
}

function Get-PsqlFailureCause {
    param([int]$ExitCode, [object[]]$Messages)

    # VERBOSITY=sqlstate の出力から安全な定型文だけを選ぶ。
    foreach ($message in $Messages) {
        $diagnostic = [string]$message
        if ($diagnostic -cnotmatch ':\s+([0-9A-Z]{5})\s*$') { continue }
        $sqlState = $Matches[1]
        switch ($sqlState) {
            '55P03' { return 'ロックを取得できません（55P03）' }
            '57014' { return 'SQLが取り消されました（57014）' }
            '22007' { return '日付の形式が不正です（22007）' }
            '22008' { return '日付が範囲外です（22008）' }
            '23502' { return 'NOT NULL制約違反（23502）' }
            '23505' { return '一意性制約違反（23505）' }
            '23514' { return 'CHECK制約違反（23514）' }
            '22P02' { return '入力値の形式が不正です（22P02）' }
            '40001' { return '同時更新のため処理を継続できません（40001）' }
            '42P01' { return 'テーブルが見つかりません（42P01）' }
            '42501' { return '権限が不足しています（42501）' }
            'P0001' { return 'SQLの事前条件を満たしていません（P0001）' }
            default { return "SQLの処理に失敗しました（$sqlState）" }
        }
    }

    switch ($ExitCode) {
        1 { return 'psqlがSQLファイルまたは入出力を処理できません' }
        2 { return 'DBへの接続を確立または維持できません' }
        default { return 'SQLまたはpsqlの処理に失敗しました' }
    }
}
