function Get-PEExportFingerprint
{
    <#
    .SYNOPSIS
    SHA-256 of an export's export.ps1, so a later run can show it is using the very same export.

    .DESCRIPTION
    The file is decoded as UTF-8, a leading BOM is removed and CRLF becomes LF before hashing, so copying the export between
    machines or artifact stores does not change the fingerprint. Returns 64 lowercase hex characters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $file = Find-PEExportFile -Path $Path
    $text = [System.IO.File]::ReadAllText($file, [System.Text.UTF8Encoding]::new($false))
    $text = $text.TrimStart([char]0xFEFF) -replace "`r`n", "`n"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-PEExportComplete
{
    <#
    .SYNOPSIS
    Says whether an export folder can be trusted as complete: it has an export.log, no component failed, and Graph returned every item it reported.

    .DESCRIPTION
    Returns Complete, LogPresent, FailedComponents (names) and Shortfalls (log lines such as
    "Graph reported 100 items but only 0 were returned"). Complete is false when the log is missing, a component is not Ok,
    or a shortfall line exists.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $logPath = Join-Path $Path 'export.log'
    $present = Test-Path -LiteralPath $logPath -PathType Leaf
    $failed = @()
    $shortfalls = @()
    if ($present)
    {
        $failed = @(Read-PEExportLog -Path $logPath | Where-Object { $_.Status -ne 'Ok' } | ForEach-Object { [string]$_.ResourceType })
        foreach ($line in [System.IO.File]::ReadLines($logPath))
        {
            $m = [regex]::Match($line, 'Graph reported (\d+) items but only (\d+) were returned')
            if ($m.Success -and [long]$m.Groups[2].Value -lt [long]$m.Groups[1].Value)
            {
                $shortfalls += $line.Trim()
            }
        }
    }

    [pscustomobject]@{
        Complete         = ($present -and $failed.Count -eq 0 -and $shortfalls.Count -eq 0)
        LogPresent       = $present
        FailedComponents = [string[]]$failed
        Shortfalls       = [string[]]$shortfalls
    }
}
