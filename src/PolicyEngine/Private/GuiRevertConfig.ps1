function Split-PEDscConfigText
{
    # Splits the text ConvertTo-PEDscConfig returns into Head (up to and including the "{" after Node localhost),
    # one text per resource block, and Tail (the closing braces). Returns $null when the text does not have that shape.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Text
    )

    $lines = @(($Text.TrimStart([char]0xFEFF)) -split "`r?`n")
    $node = -1
    for ($i = 0; $i -lt $lines.Count; $i++)
    {
        if ($lines[$i] -match '^\s{4}Node localhost\s*$') { $node = $i; break }
    }
    if ($node -lt 0 -or $node + 1 -ge $lines.Count -or $lines[$node + 1] -notmatch '^\s{4}\{\s*$') { return $null }
    $closing = -1
    for ($i = $lines.Count - 1; $i -gt $node; $i--)
    {
        if ($lines[$i] -match '^\s{4}\}\s*$') { $closing = $i; break }
    }
    if ($closing -lt 0) { return $null }

    $blocks = [System.Collections.Generic.List[string]]::new()
    $current = $null
    for ($i = $node + 2; $i -lt $closing; $i++)
    {
        if ($null -eq $current)
        {
            if ($lines[$i] -match '^\s{8}\S') { $current = [System.Collections.Generic.List[string]]::new(); $current.Add($lines[$i]) }
            continue
        }
        $current.Add($lines[$i])
        if ($lines[$i] -match '^\s{8}\}\s*$') { $blocks.Add($current -join "`n"); $current = $null }
    }
    if ($null -ne $current) { return $null }

    [pscustomobject]@{
        Head   = ($lines[0..($node + 1)] -join "`n")
        Blocks = $blocks.ToArray()
        Tail   = ($lines[$closing..($lines.Count - 1)] -join "`n").TrimEnd()
    }
}

function Get-PEGuiRevertConfig
{
    # For every finding the GUI can offer Revert on (Missing -> Create, Changed -> Update, TargetOnly -> Remove, no
    # rename hint), the resource block ConvertTo-PEDscConfig would put in the configuration. One generation for all
    # findings; when that fails, one per finding so a single bad item only loses its own preview. The plans are
    # throw-away (registered in this process only); a Remove decision is assumed because the GUI's confirmed Revert
    # records it. Returns @{ Wrapper = @{ Head; Tail }; Items = @{ <ResourceType|Key> = @{ Action; Block; Error } } }.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Check,

        [Parameter(Mandatory)]
        $Blueprint,

        [int]$Limit = 100
    )

    $actionFor = @{ Missing = 'Create'; Changed = 'Update'; TargetOnly = 'Remove' }
    $candidates = @(@($Check.Findings) | Where-Object {
            $_.State -eq 'Open' -and $actionFor.ContainsKey([string]$_.Kind) -and -not [string]::IsNullOrEmpty([string]$_.Key) -and -not $_.Hint
        } | Select-Object -First $Limit)
    $result = @{ Wrapper = $null; Items = @{} }
    if ($candidates.Count -eq 0) { return $result }

    $decisions = @($candidates | Where-Object Kind -EQ 'TargetOnly' | ForEach-Object {
            [pscustomobject]@{ Kind = 'Remove'; ResourceType = [string]$_.ResourceType; Key = [string]$_.Key; Property = $null; Value = $null; Reason = 'preview'; At = '2026-01-01T00:00:00.000Z' }
        })
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($finding in $candidates)
    {
        $id = "$($finding.ResourceType)|$($finding.Key)"
        $action = $actionFor[[string]$finding.Kind]
        try
        {
            $plan = @(New-PERectifyPlan -Findings @($finding) -Action $action -Source $Check.State -Blueprint $Blueprint -Decisions $decisions)
            $entries.Add([pscustomobject]@{ Id = $id; Action = $action; Plan = $plan[0] })
        }
        catch
        {
            $result.Items[$id] = @{ Action = $action; Block = $null; Error = $_.Exception.Message }
        }
    }
    if ($entries.Count -eq 0) { return $result }

    $generate = {
        param ($group)
        $text = ConvertTo-PEDscConfig -Plan @($group | ForEach-Object { $_.Plan }) -ConfigurationName 'PE_preview' -Target Master
        $parts = Split-PEDscConfigText -Text $text
        if ($null -eq $parts -or @($parts.Blocks).Count -ne @($group).Count) { throw 'The generated configuration has an unexpected shape.' }
        $parts
    }

    $batch = $null
    try { $batch = & $generate $entries.ToArray() } catch { $batch = $null }
    if ($null -ne $batch)
    {
        $result.Wrapper = @{ Head = $batch.Head; Tail = $batch.Tail }
        for ($i = 0; $i -lt $entries.Count; $i++)
        {
            $result.Items[$entries[$i].Id] = @{ Action = $entries[$i].Action; Block = $batch.Blocks[$i]; Error = $null }
        }
        return $result
    }

    foreach ($entry in $entries)
    {
        try
        {
            $one = & $generate @($entry)
            if ($null -eq $result.Wrapper) { $result.Wrapper = @{ Head = $one.Head; Tail = $one.Tail } }
            $result.Items[$entry.Id] = @{ Action = $entry.Action; Block = $one.Blocks[0]; Error = $null }
        }
        catch
        {
            $result.Items[$entry.Id] = @{ Action = $entry.Action; Block = $null; Error = $_.Exception.Message }
        }
    }
    return $result
}
