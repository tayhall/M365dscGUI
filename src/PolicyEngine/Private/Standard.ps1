# A standard (ASD Blueprint, later NIST or CIS) is an ordinary blueprint folder plus blueprints\<Name>\standard.json, which
# marks it read-only and holds its source. Every command that writes or applies a blueprint calls Assert-PEBlueprintNotStandard.

function Get-PEStandardInfo
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$DataRoot
    )

    $path = Join-Path (Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot) 'standard.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf))
    {
        return $null
    }
    return (Read-PEJson -Path $path)
}

function Assert-PEBlueprintNotStandard
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Action,

        [string]$DataRoot
    )

    if ($null -ne (Get-PEStandardInfo -Name $Name -DataRoot $DataRoot))
    {
        throw "Blueprint '$Name' is a standard (read-only): cannot $Action. Check a tenant against it with Invoke-PEStandardCheck and copy items into a blueprint with Copy-PEStandardItem."
    }
}

function Find-PEPlaceholder
{
    # The first string, at any depth, that names a variable ('$PrivUsers', '$ConfigurationData...'): a value the standard leaves
    # for the tenant to fill in. Returns it, or $null.
    [CmdletBinding()]
    param
    (
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value)
    {
        return $null
    }
    if ($Value -is [string])
    {
        if ($Value -match '\$[A-Za-z]')
        {
            return $Value
        }
        return $null
    }
    if ($Value -is [System.Collections.IDictionary])
    {
        $children = @($Value.get_Values())
    }
    elseif ($Value -is [System.Collections.IEnumerable])
    {
        $children = @($Value)
    }
    elseif ($Value -is [pscustomobject])
    {
        $children = @($Value.PSObject.Properties | ForEach-Object { $_.Value })
    }
    else
    {
        return $null
    }
    foreach ($child in $children)
    {
        $found = Find-PEPlaceholder -Value $child
        if ($null -ne $found)
        {
            return $found
        }
    }
    return $null
}

function Get-PEStandardItemClass
{
    # Why a normalised record of a standard cannot be checked in this tool, or $null when it can. Placeholder wins over
    # UnknownProperty (a property the pinned Microsoft365DSC does not have); Unkeyed (no usable key) comes last.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Record
    )

    foreach ($name in $Record.Properties.get_Keys())
    {
        $found = Find-PEPlaceholder -Value $Record.Properties[$name]
        if ($null -ne $found)
        {
            $text = if ($found.Length -gt 60) { $found.Substring(0, 60) } else { $found }
            return [pscustomobject]@{ Reason = 'Placeholder'; Detail = "$name = $text" }
        }
    }

    $schema = Get-PEDscResourceSchema -ResourceType ([string]$Record.ResourceType)
    if ($null -eq $schema)
    {
        return [pscustomobject]@{ Reason = 'UnknownProperty'; Detail = 'Resource type is not in the pinned Microsoft365DSC' }
    }
    $unknown = @($Record.Properties.get_Keys() | Where-Object { -not $schema.ContainsKey([string]$_) } | Sort-Object)
    if ($unknown.Count -gt 0)
    {
        return [pscustomobject]@{ Reason = 'UnknownProperty'; Detail = 'Not in the pinned Microsoft365DSC: ' + ($unknown -join ', ') }
    }

    if ([string]::IsNullOrEmpty([string]$Record.Key))
    {
        return [pscustomobject]@{ Reason = 'Unkeyed'; Detail = 'No key could be derived' }
    }
    return $null
}

function Get-PEStandardDecision
{
    # The tenant's decisions for a check against one standard: a risk accepted against another standard is left out.
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$StandardName,

        [string]$DataRoot
    )

    return @(Get-PEDecision -DataRoot $DataRoot -Tenant $Tenant | Where-Object { $_.Kind -ne 'RiskAccepted' -or [string]$_.Standard -ceq $StandardName })
}
