# Blueprints are immutable, numbered versions of a State (blueprints\<Name>\v0001.json, v0002.json, ...). A version file
# is written once and never modified; every approved update writes the next version plus a change record in
# blueprints\<Name>\changes\v000N.json (what changed, why, when and by whom).
#
# INVERTED COMPARISON. To find what changed in the master since the blueprint was taken, Get-PEBlueprintChange calls
# Compare-PEState with the FRESH MASTER STATE as -Blueprint and the STORED BLUEPRINT as -Target. Compare-PEState names
# findings relative to its -Blueprint, so in this context:
#   Missing    = a record in the master that the stored blueprint does not have (new in the master) -> add it
#   TargetOnly = a record in the stored blueprint that the master no longer has (removed)            -> remove it
#   Changed    = same key, different properties; the finding's BlueprintRecord is the master's record -> replace
# In a Changed finding's Differences, 'Blueprint' is therefore the master value and 'Target' the stored value.
# PossibleRename, Ambiguous, NotChecked, NotAvailable, Excluded and Unkeyed findings are never applied (see Approve).
# Records of excluded types (Data\ExcludedTypes.psd1) are not compared here either: they stay in the blueprint as they
# were and change only if the exclusion is lifted.

function Initialize-PEBlueprint
{
    <#
    .SYNOPSIS
    Writes version 1 of a new blueprint from a State and returns 1. Throws if the blueprint already exists.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$State,

        [string]$DataRoot
    )

    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot
    if (@(Get-PEBlueprintVersionNumber -Directory $directory).Count -gt 0)
    {
        throw "Blueprint '$Name' already exists. Use Approve-PEBlueprintChange to add versions."
    }

    # Version 1 records its own number like every later version (blueprints written before this have no Meta.Version;
    # readers count a missing version as 1). The caller's state is not modified.
    $meta = @{}
    foreach ($pair in $State.Meta.GetEnumerator())
    {
        $meta[$pair.Key] = $pair.Value
    }
    $meta['Version'] = 1
    $versioned = New-PEState -Records @($State.Records) -NotChecked @($State.NotChecked) -Meta $meta
    $document = ConvertTo-PEBlueprintDocument -State $versioned -Records $versioned.Records
    Write-PEJsonNew -Path (Get-PEBlueprintVersionFile -Directory $directory -Version 1) -InputObject $document
    $pin = Get-PEPinnedVersion -Name Microsoft365DSC
    Write-PEJson -Path (Get-PEBlueprintModulePath -Name $Name -DataRoot $DataRoot) -InputObject ([ordered]@{ ModuleVersion = $pin; Previous = $null; SetAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); SetBy = $(if ($env:USERNAME) { $env:USERNAME } else { [System.Environment]::UserName }); Reason = 'Initial blueprint' })
    return 1
}

function Get-PEBlueprint
{
    <#
    .SYNOPSIS
    Reads a blueprint version (an integer or 'latest', the default) as a State.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [ValidatePattern('^(latest|\d+)$')]
        [string]$Version = 'latest',

        [string]$DataRoot
    )

    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot
    $existing = @(Get-PEBlueprintVersionNumber -Directory $directory)
    if ($existing.Count -eq 0)
    {
        throw "Blueprint '$Name' not found under $directory."
    }

    if ($Version -eq 'latest')
    {
        $number = $existing[-1]
    }
    else
    {
        $number = [int]$Version
        if ($existing -notcontains $number)
        {
            throw "Blueprint '$Name' has no version $number (available: $($existing -join ', '))."
        }
    }

    $data = Read-PEJson -Path (Get-PEBlueprintVersionFile -Directory $directory -Version $number)
    $meta = @{}
    if ($null -ne $data.Meta)
    {
        foreach ($property in $data.Meta.PSObject.Properties)
        {
            $meta[$property.Name] = $property.Value
        }
    }
    return (New-PEState -Records @($data.Records) -NotChecked @($data.NotChecked) -Meta $meta)
}

function Get-PEBlueprintChange
{
    <#
    .SYNOPSIS
    Compares the latest blueprint version with a fresh master state. Kinds are inverted; see the top of this file:
    Missing = new in the master, TargetOnly = removed from the master, Changed = modified in the master.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$MasterState,

        [string]$DataRoot
    )

    $current = Get-PEBlueprint -Name $Name -Version 'latest' -DataRoot $DataRoot
    Compare-PEState -Blueprint $MasterState -Target $current
}

function Approve-PEBlueprintChange
{
    <#
    .SYNOPSIS
    Writes the next blueprint version containing only the accepted changes, plus a change record. Returns the version.

    .DESCRIPTION
    The changes are re-derived from -MasterState; each accepted finding must match a (Kind, ResourceType, Key) of that
    set, otherwise nothing is written. The records written come from -MasterState and the current version, never from
    the supplied finding objects. PossibleRename, Ambiguous, NotChecked, NotAvailable, Excluded and Unkeyed findings
    are rejected: resolve them first (they are not blueprint changes this function can apply).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$MasterState,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Accept,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [string]$DataRoot
    )

    $accepted = @($Accept | Where-Object { $null -ne $_ })
    if ($accepted.Count -eq 0)
    {
        throw 'No findings to accept: pass at least one finding from Get-PEBlueprintChange.'
    }

    $applicable = @('Missing', 'TargetOnly', 'Changed')
    foreach ($finding in $accepted)
    {
        if ($finding.Kind -notin $applicable)
        {
            throw "Cannot accept a $($finding.Kind) finding ($($finding.ResourceType) '$($finding.Key)'): resolve it first. Only Missing, TargetOnly and Changed findings can be approved."
        }
    }

    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot
    $lock = Enter-PEBlueprintLock -Directory $directory
    try
    {
        return (Write-PEBlueprintVersion -Name $Name -MasterState $MasterState -Accepted $accepted -Reason $Reason -DataRoot $DataRoot)
    }
    finally
    {
        Exit-PEBlueprintLock -Lock $lock
    }
}
