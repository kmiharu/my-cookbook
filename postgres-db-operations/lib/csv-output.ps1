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

function Save-CopyCsv {
    param([string]$SourceFile, [string]$DestinationFile)

    $normalizedFile = "$DestinationFile.normalized.part"
    try {
        $readyFile = $SourceFile
        if (Restore-CsvNewlines -SourceFile $SourceFile -DestinationFile $normalizedFile) {
            $readyFile = $normalizedFile
        }
        Move-Item -LiteralPath $readyFile -Destination $DestinationFile -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $normalizedFile -ErrorAction SilentlyContinue
    }
}
