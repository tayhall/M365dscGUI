function Copy-PEStandardItem
{
    <#
    .SYNOPSIS
    Promotes items of a standard into a blueprint as a new version of that blueprint. Returns the new version number. No tenant is written to.

    .DESCRIPTION
    A new item is added as the standard states it. For an item the blueprint already has, the properties the standard states overwrite the
    same properties of the blueprint's record and every other property is kept. Each copied record carries Provenance (standard, source
    version, control id when known), so Get-PEStandardAdoption can say which items of a standard a blueprint has adopted. Nothing in the
    blueprint is removed. -ExpectedVersion is the latest version of the blueprint the caller reviewed: when it has moved on, nothing is
    written. The check and the write happen under the blueprint's lock. To apply the result to a tenant, use the usual Revert path from
    that blueprint: a tenant is only written from its own blueprint.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Item')]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Standard,

        [Parameter(Mandatory)]
        [string]$To,

        # Items to copy: anything with ResourceType and Key.
        [Parameter(Mandatory, ParameterSetName = 'Item')]
        [object[]]$Item,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [Parameter(Mandatory)]
        [int]$ExpectedVersion,

        [string]$DataRoot
    )

    Assert-PEBlueprintNotStandard -Name $To -Action 'copy standard items into it' -DataRoot $DataRoot
    if ($null -eq (Get-PEStandardInfo -Name $Standard -DataRoot $DataRoot))
    {
        throw "'$Standard' is not a standard (import one with Import-PEStandard)."
    }
    $source = Get-PEBlueprint -Name $Standard -DataRoot $DataRoot
    $chosen = if ($All) { @($source.Records) } else
    {
        foreach ($entry in @($Item | Where-Object { $null -ne $_ }))
        {
            $match = @($source.Records | Where-Object { [string]$_.ResourceType -ieq [string]$entry.ResourceType -and [string]$_.Key -ieq [string]$entry.Key })
            if ($match.Count -ne 1)
            {
                throw "Standard '$Standard' has no item $($entry.ResourceType) '$($entry.Key)'."
            }
            $match[0]
        }
    }

    $directory = Get-PEBlueprintDirectory -Name $To -DataRoot $DataRoot
    $lock = Enter-PEBlueprintLock -Directory $directory
    try
    {
        $latest = @(Get-PEBlueprintVersionNumber -Directory $directory)[-1]
        if ($latest -ne $ExpectedVersion)
        {
            throw "Blueprint '$To' has changed since the review (version $latest, expected $ExpectedVersion). Check again and retry."
        }
        $target = Get-PEBlueprint -Name $To -DataRoot $DataRoot
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($record in @($target.Records))
        {
            $records.Add($record)
        }
        foreach ($record in @($chosen))
        {
            $wanted = Get-PEMatchKey -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key)
            $index = -1
            for ($i = 0; $i -lt $records.Count; $i++)
            {
                if (-not [string]::IsNullOrEmpty([string]$records[$i].Key) -and (Get-PEMatchKey -ResourceType ([string]$records[$i].ResourceType) -Key ([string]$records[$i].Key)) -eq $wanted)
                {
                    $index = $i
                    break
                }
            }
            if ($index -lt 0)
            {
                $records.Add($record)
                continue
            }
            $existing = $records[$index]
            $properties = [ordered]@{}
            $existingBag = Get-PEPropertyBag -Record $existing
            foreach ($name in $existingBag.get_Keys())
            {
                $properties[$name] = $existingBag[$name]
            }
            $stated = Get-PEPropertyBag -Record $record
            foreach ($name in $stated.get_Keys())
            {
                $properties[$name] = $stated[$name]
            }
            $records[$index] = [pscustomobject]@{
                ResourceType = $existing.ResourceType
                Key          = $existing.Key
                Workload     = $existing.Workload
                TenantId     = $(if ($existing.PSObject.Properties['TenantId']) { $existing.TenantId } else { $null })
                Properties   = $properties
                Provenance   = $record.Provenance
            }
        }

        $proposed = New-PEState -Records $records.ToArray() -NotChecked @($target.NotChecked) -Meta $target.Meta
        $changes = @(Compare-PEState -Blueprint $proposed -Target $target | Where-Object { $_.Kind -in 'Missing', 'Changed' })
        if ($changes.Count -eq 0)
        {
            throw "Nothing to copy: blueprint '$To' already has every chosen item as the standard states it."
        }
        return (Write-PEBlueprintVersion -Name $To -MasterState $proposed -Accepted $changes -Reason $Reason -DataRoot $DataRoot)
    }
    finally
    {
        Exit-PEBlueprintLock -Lock $lock
    }
}

function Get-PEStandardAdoption
{
    <#
    .SYNOPSIS
    For each item of a standard, whether a blueprint has adopted it (a record in the blueprint with provenance naming the standard), and the
    source version it was adopted from. An adopted item still counts after the blueprint edited it.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Standard,

        [Parameter(Mandatory)]
        [string]$Blueprint,

        [string]$DataRoot
    )

    if ($null -eq (Get-PEStandardInfo -Name $Standard -DataRoot $DataRoot))
    {
        throw "'$Standard' is not a standard (import one with Import-PEStandard)."
    }
    $adopted = @{}
    foreach ($record in @((Get-PEBlueprint -Name $Blueprint -DataRoot $DataRoot).Records))
    {
        if ([string]::IsNullOrEmpty([string]$record.Key) -or -not $record.PSObject.Properties['Provenance'] -or $null -eq $record.Provenance)
        {
            continue
        }
        if ([string]$record.Provenance.Standard -ceq $Standard)
        {
            $adopted[(Get-PEMatchKey -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key))] = [string]$record.Provenance.SourceVersion
        }
    }
    foreach ($record in @((Get-PEBlueprint -Name $Standard -DataRoot $DataRoot).Records))
    {
        $matchKey = Get-PEMatchKey -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key)
        [pscustomobject]@{
            ResourceType  = [string]$record.ResourceType
            Key           = [string]$record.Key
            Adopted       = $adopted.ContainsKey($matchKey)
            SourceVersion = $(if ($adopted.ContainsKey($matchKey)) { $adopted[$matchKey] } else { $null })
        }
    }
}
