# References between resources (Data\References.psd1): apply order, required parents, GUID resolution.
$script:PEReferences = $null

function Get-PEReferenceMap
{
    # Type (case-insensitive) -> reference entries, from Data\References.psd1.
    [CmdletBinding()]
    param ()

    if ($null -eq $script:PEReferences)
    {
        $data = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'References.psd1')
        $map = [System.Collections.Generic.Dictionary[string, object[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($type in $data.References.get_Keys())
        {
            $map[[string]$type] = @($data.References[$type])
        }
        $script:PEReferences = $map
    }
    return $script:PEReferences
}

function Get-PEApplyDepth
{
    # How many parents deep a type is (0 = refers to nothing). Parents are applied first; a cycle in the data stops at the
    # first repeat.
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [string[]]$Seen = @()
    )

    $map = Get-PEReferenceMap
    if (-not $map.ContainsKey($ResourceType) -or $Seen -icontains $ResourceType)
    {
        return 0
    }
    $deepest = 0
    foreach ($parent in @($map[$ResourceType] | ForEach-Object { [string]$_.ParentType } | Sort-Object -Unique))
    {
        $deepest = [Math]::Max($deepest, 1 + (Get-PEApplyDepth -ResourceType $parent -Seen (@($Seen) + $ResourceType)))
    }
    return $deepest
}

function Sort-PERevertEntry
{
    # Orders the chosen entries (objects with Action and Finding) for one apply: Create, then Update, then Remove; within Create and
    # Update parents before children (Get-PEApplyDepth), within Remove children before parents; ties keep the selection order.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Entry
    )

    $rank = @{ Create = 0; Update = 1; Remove = 2 }
    $index = 0
    $decorated = foreach ($item in $Entry)
    {
        $depth = Get-PEApplyDepth -ResourceType ([string]$item.Finding.ResourceType)
        [pscustomobject]@{ Entry = $item; Rank = $rank[[string]$item.Action]; Depth = $(if ($item.Action -eq 'Remove') { -$depth } else { $depth }); Index = $index++ }
    }
    @($decorated | Sort-Object Rank, Depth, Index | ForEach-Object { $_.Entry })
}

function Resolve-PEReferenceGuid
{
    # Replaces a GUID reference by the parent's Key (References.psd1, ResolveGuid) in the raw records of an export. The parent's Id
    # comes from the parent records of the same export, or from -ReferenceMap ('<parenttype>|<id>' -> Key), which is filled with
    # what this export holds so a caller can carry it to the next one. A GUID with no known parent is left as it is.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Record,

        [System.Collections.IDictionary]$ReferenceMap = @{}
    )

    $map = Get-PEReferenceMap
    $parentTypes = @($map.get_Keys() | ForEach-Object { $map[$_] } | Where-Object { $_.ResolveGuid } | ForEach-Object { [string]$_.ParentType } | Sort-Object -Unique)
    foreach ($item in $Record)
    {
        if ($parentTypes -icontains [string]$item.ResourceType -and $item.Properties.Contains('Id') -and -not [string]::IsNullOrWhiteSpace([string]$item.Properties['Id']))
        {
            $key = Get-PEResourceKey -ResourceType ([string]$item.ResourceType) -Properties $item.Properties
            if ($key)
            {
                $ReferenceMap[([string]$item.ResourceType).ToLowerInvariant() + '|' + ([string]$item.Properties['Id']).ToLowerInvariant()] = $key
            }
        }
    }
    foreach ($item in $Record)
    {
        if (-not $map.ContainsKey([string]$item.ResourceType))
        {
            continue
        }
        foreach ($reference in @($map[[string]$item.ResourceType] | Where-Object { $_.ResolveGuid }))
        {
            $name = [string]$reference.Property
            $value = [string]$item.Properties[$name]
            $guid = [guid]::Empty
            if ($value -and [guid]::TryParse($value, [ref]$guid))
            {
                $lookup = ([string]$reference.ParentType).ToLowerInvariant() + '|' + $value.ToLowerInvariant()
                if ($ReferenceMap.Contains($lookup))
                {
                    $item.Properties[$name] = $ReferenceMap[$lookup]
                }
            }
        }
    }
}

function Get-PEGuidParentType
{
    # The parent types whose Ids are needed to resolve the GUID references (ResolveGuid) of a resource type.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType
    )

    $map = Get-PEReferenceMap
    if ($map.ContainsKey($ResourceType))
    {
        @($map[$ResourceType] | Where-Object { $_.ResolveGuid } | ForEach-Object { [string]$_.ParentType } | Sort-Object -Unique)
    }
}
