function New-OperationLog {
    param([string]$Directory, [string]$Operation)

    $startedAt = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $runName = "${startedAt}_${Operation}_${PID}"
    $path = Join-Path $Directory "$runName.log"
    try {
        $null = [System.IO.Directory]::CreateDirectory($Directory)
        $file = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew)
        $file.Dispose()
    } catch {
        throw "ログを作成できません。保存先=$path 理由=$($_.Exception.Message)"
    }
    return [pscustomobject]@{ Path = $path; RunName = $runName }
}

function Write-Log {
    param(
        [string]$Path,
        [ValidateSet('INFO', 'ERROR')][string]$Level,
        [string]$Message,
        [System.Diagnostics.Stopwatch]$Stopwatch
    )

    if ($Stopwatch -and $Path) {
        $elapsed = '{0:F3}' -f $Stopwatch.Elapsed.TotalSeconds
        $Message += "  所要時間=${elapsed}秒"
    }
    $singleLine = $Message -replace '[\r\n]+', ' '
    if (-not $Path) {
        [Console]::Error.WriteLine($singleLine)
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$Level] $singleLine"
    try {
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, $utf8)
    } catch {
        $writeError = "ログに追記できません。保存先=$Path 理由=$($_.Exception.Message)"
        if ($Level -eq 'INFO') { throw $writeError }
        [Console]::Error.WriteLine($writeError)
    }
    [Console]::Error.WriteLine($line)
}
