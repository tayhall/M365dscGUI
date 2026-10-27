function Get-PEBlueprintDirectory
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$DataRoot
    )

    # The name becomes a folder name: no separators, no dot-only names, nothing that could leave blueprints\.
    if ($Name -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z' -or $Name.Contains('..') -or $Name.EndsWith('.'))
    {
        throw "Invalid blueprint name '$Name': use letters, digits, '.', '_' and '-' only, and do not end with '.'."
    }
    # Windows device names (also with an extension, such as con.txt) cannot be used as folder names.
    if ($Name -match '\A(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?\z')
    {
        throw "Invalid blueprint name '$Name': reserved Windows device name."
    }

    $root = Get-PEDataRoot -Override $DataRoot
    return (Join-Path (Join-Path $root 'blueprints') $Name)
}

function Get-PEBlueprintVersionFile
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [int]$Version
    )

    return (Join-Path $Directory ('v{0:D4}.json' -f $Version))
}

function Get-PEBlueprintVersionNumber
{
    # Existing version numbers of a blueprint folder, ascending. Empty when the folder does not exist.
    [CmdletBinding()]
    [OutputType([int[]])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container))
    {
        return @()
    }
    $numbers = foreach ($file in Get-ChildItem -LiteralPath $Directory -File)
    {
        if ($file.Name -match '^v(\d{4,})\.json$')
        {
            [int]$Matches[1]
        }
    }
    return @($numbers | Sort-Object)
}

function ConvertTo-PEBlueprintDocument
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $State,

        [AllowNull()]
        [object[]]$Records
    )

    [ordered]@{
        Records    = @($Records)
        NotChecked = @($State.NotChecked)
        Meta       = $State.Meta
    }
}

function Get-PEBlueprintFindingId
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        $Finding
    )

    if ([string]::IsNullOrEmpty([string]$Finding.Key))
    {
        return $null
    }
    return ([string]$Finding.Kind) + '|' + (Get-PEMatchKey -ResourceType ([string]$Finding.ResourceType) -Key ([string]$Finding.Key))
}

function Write-PEBlueprintVersion
{
    # Body of Approve-PEBlueprintChange; runs while the per-blueprint lock is held.
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [string]$Name,
        $MasterState,
        [object[]]$Accepted,
        [string]$Reason,
        [string]$DataRoot
    )

    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot
    $current = Get-PEBlueprint -Name $Name -Version 'latest' -DataRoot $DataRoot
    $derived = @(Compare-PEState -Blueprint $MasterState -Target $current)
    $byId = @{}
    foreach ($finding in $derived)
    {
        $id = Get-PEBlueprintFindingId -Finding $finding
        if ($id)
        {
            $byId[$id] = $finding
        }
    }

    # Resolve every accepted finding against the re-derived set before anything is written.
    $selected = [ordered]@{}
    foreach ($finding in $accepted)
    {
        $id = Get-PEBlueprintFindingId -Finding $finding
        if (-not $id -or -not $byId.ContainsKey($id))
        {
            throw "Finding $($finding.Kind) $($finding.ResourceType) '$($finding.Key)' is not part of the current comparison of the master with blueprint '$Name'. Re-run Get-PEBlueprintChange."
        }
        $selected[$id] = $byId[$id]
    }

    $number = @(Get-PEBlueprintVersionNumber -Directory $directory)[-1] + 1
    $versionFile = Get-PEBlueprintVersionFile -Directory $directory -Version $number
    $changeFile = Join-Path (Join-Path $directory 'changes') ('v{0:D4}.json' -f $number)
    if (Test-Path -LiteralPath $versionFile)
    {
        throw "File already exists, refusing to overwrite: $versionFile"
    }
    if (Test-Path -LiteralPath $changeFile)
    {
        # The version file is written last, so a change record without a version file is left over from a failed attempt.
        Write-Warning "Replacing orphaned change record from a failed attempt: $changeFile"
        Remove-Item -LiteralPath $changeFile -Force
    }

    # Apply to a copy of the current records (records without a key are carried over untouched).
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($current.Records))
    {
        $records.Add($record)
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($finding in $selected.Values)
    {
        $wanted = Get-PEMatchKey -ResourceType ([string]$finding.ResourceType) -Key ([string]$finding.Key)
        $index = -1
        for ($i = 0; $i -lt $records.Count; $i++)
        {
            $existing = $records[$i]
            if (-not [string]::IsNullOrEmpty([string]$existing.Key) -and (Get-PEMatchKey -ResourceType ([string]$existing.ResourceType) -Key ([string]$existing.Key)) -eq $wanted)
            {
                $index = $i
                break
            }
        }

        switch ($finding.Kind)
        {
            'Missing'
            {
                $records.Add($finding.BlueprintRecord)
            }
            'TargetOnly'
            {
                if ($index -ge 0)
                {
                    $records.RemoveAt($index)
                }
            }
            'Changed'
            {
                if ($index -ge 0)
                {
                    $records[$index] = $finding.BlueprintRecord
                }
            }
        }

        # 'Blueprint' in the comparison is the master value; the change record calls them New / Previous.
        $differences = foreach ($difference in @($finding.Differences))
        {
            [ordered]@{ Property = $difference.Property; New = $difference.Blueprint; Previous = $difference.Target }
        }
        $changes.Add([ordered]@{
                Kind         = $finding.Kind
                ResourceType = $finding.ResourceType
                Key          = $finding.Key
                Workload     = $finding.Workload
                Differences  = @($differences)
            })
    }

    # Keep only the NotChecked entries that are still not checked in the master; a type that now exports fine is
    # cleared, so its records show up as findings in the next comparison.
    $masterNotChecked = Get-PENotCheckedMap -NotChecked $MasterState.NotChecked
    $notChecked = @(@($current.NotChecked) | Where-Object { $null -ne $_ -and $masterNotChecked.ContainsKey([string]$_.ResourceType) })

    $meta = @{}
    foreach ($pair in $current.Meta.GetEnumerator())
    {
        $meta[$pair.Key] = $pair.Value
    }
    foreach ($metaName in @('ExportedAt', 'Source'))
    {
        $metaValue = Get-PEMetaValue -Meta $MasterState.Meta -Name $metaName
        if ($null -ne $metaValue)
        {
            $meta[$metaName] = $metaValue
        }
    }
    $meta['Version'] = $number
    $newState = New-PEState -Records $records.ToArray() -NotChecked $notChecked -Meta $meta

    $changeRecord = [ordered]@{
        Version          = $number
        Name             = $Name
        Reason           = $Reason
        MasterExportedAt = Get-PEMetaValue -Meta $MasterState.Meta -Name 'ExportedAt'
        At               = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        User             = $env:USERNAME
        Changes          = $changes.ToArray()
    }

    # The version file is the commit point: written last, with CreateNew.
    Write-PEJsonNew -Path $changeFile -InputObject $changeRecord
    Write-PEJsonNew -Path $versionFile -InputObject (ConvertTo-PEBlueprintDocument -State $newState -Records $newState.Records)
    return $number
}

function Get-PEMetaValue
{
    # Reads a Meta value from an IDictionary (a fresh state) or a PSCustomObject (a state read back from JSON).
    [CmdletBinding()]
    param
    (
        [AllowNull()]
        $Meta,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Meta)
    {
        return $null
    }
    if ($Meta -is [System.Collections.IDictionary])
    {
        if ($Meta.Contains($Name))
        {
            return $Meta[$Name]
        }
        return $null
    }
    $property = $Meta.PSObject.Properties[$Name]
    if ($property)
    {
        return $property.Value
    }
    return $null
}

function Enter-PEBlueprintLock
{
    # Per-blueprint lock file. Never removed automatically: a stale lock must be deleted by a person.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container))
    {
        throw "Blueprint folder not found: $Directory"
    }
    $path = Join-Path $Directory '.lock'
    try
    {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException]
    {
        if (Test-Path -LiteralPath $path)
        {
            $created = (Get-Item -LiteralPath $path).CreationTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
            throw "Another approval is in progress (lock $path, created $created); if no approval is running, delete the lock file."
        }
        throw
    }
    try
    {
        $info = '{0} pid={1} {2}' -f $env:USERNAME, $PID, [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($info)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally
    {
        $stream.Dispose()
    }
    return $path
}

function Exit-PEBlueprintLock
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Lock
    )

    Remove-Item -LiteralPath $Lock -Force -ErrorAction SilentlyContinue
}
