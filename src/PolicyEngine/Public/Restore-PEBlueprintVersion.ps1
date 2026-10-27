function Restore-PEBlueprintVersion
{
    <#
    .SYNOPSIS
    Records a new version of a blueprint that is a copy of an earlier one, or restores single items from it.

    .DESCRIPTION
    Versions are never overwritten or deleted: restoring v4 while v9 is current writes v10 with what v4 held, and the history keeps
    v5 to v9. Without -Item the whole blueprint becomes what the old version was. With -Item only those items (ResourceType and Key)
    are set as the old version had them: replaced when both versions hold them, added when only the old one did, removed when only
    the current one has them; every other item stays as it is.

    The change record names the version it was restored from (RestoredFrom), so the history can show it. Throws when the old
    version is the current one, does not exist, or does not differ from the current one for what was asked.

    Returns Version (the new number), RestoredFrom and Items (ResourceType and Key of what changed). No tenant is touched.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Version,

        # Restore only these items: anything with ResourceType and Key.
        [object[]]$Item,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [string]$DataRoot
    )

    Assert-PEBlueprintNotStandard -Name $Name -Action 'restore a version' -DataRoot $DataRoot
    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot
    $lock = Enter-PEBlueprintLock -Directory $directory
    try
    {
        $numbers = @(Get-PEBlueprintVersionNumber -Directory $directory)
        if ($numbers -notcontains $Version)
        {
            throw "Blueprint '$Name' has no version $Version."
        }
        if ($Version -eq $numbers[-1])
        {
            throw "v$Version is already the current version of blueprint '$Name'."
        }
        $old = Get-PEBlueprint -Name $Name -Version $Version -DataRoot $DataRoot
        $current = Get-PEBlueprint -Name $Name -Version 'latest' -DataRoot $DataRoot
        $keyOf = { param ($record) Get-PEMatchKey -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key) }
        $hasKey = { param ($record) -not [string]::IsNullOrEmpty([string]$record.Key) }

        # The records of the new version.
        $newRecords = [System.Collections.Generic.List[object]]::new()
        if (@($Item | Where-Object { $null -ne $_ }).Count -eq 0)
        {
            foreach ($record in @($old.Records)) { $newRecords.Add($record) }
        }
        else
        {
            $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in @($Item | Where-Object { $null -ne $_ }))
            {
                [void]$wanted.Add((Get-PEMatchKey -ResourceType ([string]$entry.ResourceType) -Key ([string]$entry.Key)))
            }
            $oldByKey = @{}
            foreach ($record in @($old.Records)) { if (& $hasKey $record) { $oldByKey[(& $keyOf $record)] = $record } }
            $placed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($record in @($current.Records))
            {
                $mk = if (& $hasKey $record) { & $keyOf $record } else { $null }
                if ($null -ne $mk -and $wanted.Contains($mk))
                {
                    [void]$placed.Add($mk)
                    if ($oldByKey.ContainsKey($mk)) { $newRecords.Add($oldByKey[$mk]) }
                }
                else
                {
                    $newRecords.Add($record)
                }
            }
            foreach ($mk in $wanted)
            {
                if (-not $placed.Contains($mk) -and $oldByKey.ContainsKey($mk)) { $newRecords.Add($oldByKey[$mk]) }
            }
        }

        # What changed, by key, in the words of a change record (Missing = added to the blueprint, TargetOnly = removed from it).
        $currentByKey = @{}
        foreach ($record in @($current.Records)) { if (& $hasKey $record) { $currentByKey[(& $keyOf $record)] = $record } }
        $newByKey = @{}
        foreach ($record in $newRecords) { if (& $hasKey $record) { $newByKey[(& $keyOf $record)] = $record } }
        $changes = [System.Collections.Generic.List[object]]::new()
        foreach ($mk in $newByKey.Keys)
        {
            $record = $newByKey[$mk]
            if (-not $currentByKey.ContainsKey($mk))
            {
                $changes.Add([ordered]@{ Kind = 'Missing'; ResourceType = $record.ResourceType; Key = $record.Key; Workload = (Get-PERecordWorkload -Record $record); Differences = @() })
                continue
            }
            # Returned as one array object (see Get-PEPropertyDifference), so it is not wrapped in @().
            $differences = Get-PEPropertyDifference (Get-PEPropertyBag $record) (Get-PEPropertyBag $currentByKey[$mk])
            if ($differences.Count -gt 0)
            {
                $changes.Add([ordered]@{
                        Kind         = 'Changed'
                        ResourceType = $record.ResourceType
                        Key          = $record.Key
                        Workload     = (Get-PERecordWorkload -Record $record)
                        Differences  = @(foreach ($difference in $differences) { [ordered]@{ Property = $difference.Property; New = $difference.Blueprint; Previous = $difference.Target } })
                    })
            }
        }
        foreach ($mk in $currentByKey.Keys)
        {
            if (-not $newByKey.ContainsKey($mk))
            {
                $record = $currentByKey[$mk]
                $changes.Add([ordered]@{ Kind = 'TargetOnly'; ResourceType = $record.ResourceType; Key = $record.Key; Workload = (Get-PERecordWorkload -Record $record); Differences = @() })
            }
        }
        if ($changes.Count -eq 0)
        {
            throw "v$Version does not differ from the current version of blueprint '$Name' for what was asked."
        }

        $number = $numbers[-1] + 1
        $versionFile = Get-PEBlueprintVersionFile -Directory $directory -Version $number
        $changeFile = Join-Path (Join-Path $directory 'changes') ('v{0:D4}.json' -f $number)
        if (Test-Path -LiteralPath $versionFile)
        {
            throw "File already exists, refusing to overwrite: $versionFile"
        }
        if (Test-Path -LiteralPath $changeFile)
        {
            Write-Warning "Replacing orphaned change record from a failed attempt: $changeFile"
            Remove-Item -LiteralPath $changeFile -Force
        }

        $whole = @($Item | Where-Object { $null -ne $_ }).Count -eq 0
        $meta = @{}
        foreach ($pair in $current.Meta.GetEnumerator()) { $meta[$pair.Key] = $pair.Value }
        if ($whole)
        {
            foreach ($metaName in @('ExportedAt', 'Source'))
            {
                $metaValue = Get-PEMetaValue -Meta $old.Meta -Name $metaName
                if ($null -ne $metaValue) { $meta[$metaName] = $metaValue }
            }
        }
        $meta['Version'] = $number
        $newState = New-PEState -Records $newRecords.ToArray() -NotChecked @($(if ($whole) { $old.NotChecked } else { $current.NotChecked })) -Meta $meta

        $changeRecord = [ordered]@{
            Version      = $number
            Name         = $Name
            Reason       = $Reason
            RestoredFrom = $Version
            At           = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            User         = $env:USERNAME
            Changes      = $changes.ToArray()
        }
        # The version file is the commit point: written last, with CreateNew.
        Write-PEJsonNew -Path $changeFile -InputObject $changeRecord
        Write-PEJsonNew -Path $versionFile -InputObject (ConvertTo-PEBlueprintDocument -State $newState -Records $newState.Records)

        [pscustomobject]@{
            Version      = $number
            RestoredFrom = $Version
            Items        = @($changes | ForEach-Object { [pscustomobject]@{ ResourceType = [string]$_.ResourceType; Key = [string]$_.Key } })
        }
    }
    finally
    {
        Exit-PEBlueprintLock -Lock $lock
    }
}
