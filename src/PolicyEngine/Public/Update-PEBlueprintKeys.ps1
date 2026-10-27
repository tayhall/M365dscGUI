function Update-PEBlueprintKeys
{
    <#
    .SYNOPSIS
    Writes a new blueprint version whose records carry the keys and references the current rules produce.

    .DESCRIPTION
    Records are matched by the Key stored in the blueprint, so when Data\KeyMap.psd1 changes (a composite key for a type) or a
    GUID reference is turned into the parent's Key (Data\References.psd1, ResolveGuid), the stored records must follow, or every
    record of the type would read as Missing and TargetOnly. This recomputes every record's Key from its properties and, with
    -ExportPath (raw export files the blueprint's records came from, which still hold the parents' Ids), resolves the GUID
    references. Nothing else in a record changes. Writes one version (reason required) and a change record of the keys and
    properties that moved; writes nothing when nothing moves. Returns the new version number, or $null.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        # Raw export files (full-export.ps1) that hold the Ids of the parents referenced by GUID.
        [string[]]$ExportPath = @(),

        # Report what would move (the change list) and write nothing.
        [switch]$DryRun,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $root
    $lock = Enter-PEBlueprintLock -Directory $directory
    try
    {
        $current = Get-PEBlueprint -Name $Name -Version 'latest' -DataRoot $root
        $referenceMap = @{}
        foreach ($path in $ExportPath)
        {
            $raw = @(Read-PEExport -Path $path)
            Resolve-PEReferenceGuid -Record $raw -ReferenceMap $referenceMap
        }

        $records = [System.Collections.Generic.List[object]]::new()
        $changes = [System.Collections.Generic.List[object]]::new()
        foreach ($record in @($current.Records))
        {
            $bag = Get-PEPropertyBag -Record $record
            $copy = [ordered]@{}
            foreach ($propertyName in $bag.get_Keys())
            {
                $copy[$propertyName] = $bag[$propertyName]
            }
            $before = ConvertTo-PECanonicalValue $copy
            $shell = [pscustomobject]@{ ResourceType = [string]$record.ResourceType; Properties = $copy }
            Resolve-PEReferenceGuid -Record @($shell) -ReferenceMap $referenceMap
            $key = [string]$record.Key
            if (-not [string]::IsNullOrEmpty($key))
            {
                # Keyed from the properties as the normaliser sees them: ids the ignore list removes are not part of a key.
                $newKey = Get-PEResourceKey -ResourceType ([string]$record.ResourceType) -Properties $copy
                if (-not [string]::IsNullOrEmpty($newKey))
                {
                    $key = $newKey
                }
            }
            $moved = ($key -cne [string]$record.Key) -or ((ConvertTo-PECanonicalValue $copy) -cne $before)
            if ($moved)
            {
                $differences = [System.Collections.Generic.List[object]]::new()
                if ($key -cne [string]$record.Key)
                {
                    $differences.Add([ordered]@{ Property = 'Key'; New = $key; Previous = [string]$record.Key })
                }
                foreach ($propertyName in $copy.get_Keys())
                {
                    if ((ConvertTo-PECanonicalValue $copy[$propertyName]) -cne (ConvertTo-PECanonicalValue $bag[$propertyName]))
                    {
                        $differences.Add([ordered]@{ Property = $propertyName; New = $copy[$propertyName]; Previous = $bag[$propertyName] })
                    }
                }
                $changes.Add([ordered]@{ Kind = 'Changed'; ResourceType = [string]$record.ResourceType; Key = $key; Workload = $record.Workload; Differences = @($differences) })
                $records.Add([pscustomobject]@{ ResourceType = $record.ResourceType; Key = $key; Workload = $record.Workload; TenantId = $record.TenantId; Properties = $copy })
            }
            else
            {
                $records.Add($record)
            }
        }
        if ($changes.Count -eq 0)
        {
            Write-Verbose "Blueprint '$Name': every key and reference is already current."
            return $null
        }
        if ($DryRun)
        {
            return $changes.ToArray()
        }

        $number = @(Get-PEBlueprintVersionNumber -Directory $directory)[-1] + 1
        $versionFile = Get-PEBlueprintVersionFile -Directory $directory -Version $number
        $changeFile = Join-Path (Join-Path $directory 'changes') ('v{0:D4}.json' -f $number)
        if (Test-Path -LiteralPath $versionFile)
        {
            throw "File already exists, refusing to overwrite: $versionFile"
        }
        $meta = @{}
        foreach ($pair in $current.Meta.GetEnumerator())
        {
            $meta[$pair.Key] = $pair.Value
        }
        $meta['Version'] = $number
        $newState = New-PEState -Records $records.ToArray() -NotChecked @($current.NotChecked) -Meta $meta
        $changeRecord = [ordered]@{
            Version          = $number
            Name             = $Name
            Reason           = $Reason
            MasterExportedAt = Get-PEMetaValue -Meta $current.Meta -Name 'ExportedAt'
            At               = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            User             = $env:USERNAME
            Changes          = $changes.ToArray()
        }
        Write-PEJsonNew -Path $changeFile -InputObject $changeRecord
        Write-PEJsonNew -Path $versionFile -InputObject (ConvertTo-PEBlueprintDocument -State $newState -Records $newState.Records)
        return $number
    }
    finally
    {
        Exit-PEBlueprintLock -Lock $lock
    }
}
