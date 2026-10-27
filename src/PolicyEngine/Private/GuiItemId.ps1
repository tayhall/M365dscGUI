function ConvertTo-PEGuiItemId
{
    # Same id the GUI derives (gui\PEGui.psm1, ConvertTo-PEGuiItemId): ResourceType~Key with every character outside
    # [A-Za-z0-9_.-] percent-encoded as UTF-8. A test keeps the two in step.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $encoded = foreach ($character in $Key.ToCharArray())
    {
        if ("$character" -match '^[A-Za-z0-9_.-]$')
        {
            "$character"
        }
        else
        {
            ([System.Text.Encoding]::UTF8.GetBytes("$character") | ForEach-Object { '%{0:X2}' -f $_ }) -join ''
        }
    }
    return "$ResourceType~$($encoded -join '')"
}

function Compare-PEGuiProperty
{
    # Settings that differ between two property bags, as @{Property; Blueprint; Target} (blueprint side first).
    [CmdletBinding()]
    param
    (
        $Blueprint,
        $Target
    )

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($bag in @($Blueprint, $Target))
    {
        if ($null -eq $bag) { continue }
        foreach ($property in $bag.PSObject.Properties) { if (-not $names.Contains($property.Name)) { $names.Add($property.Name) } }
    }
    foreach ($name in $names)
    {
        $left = if ($null -ne $Blueprint -and $Blueprint.PSObject.Properties[$name]) { $Blueprint.$name } else { $null }
        $right = if ($null -ne $Target -and $Target.PSObject.Properties[$name]) { $Target.$name } else { $null }
        if ((ConvertTo-Json -InputObject $left -Compress -Depth 10) -cne (ConvertTo-Json -InputObject $right -Compress -Depth 10))
        {
            [pscustomobject]@{ Property = $name; Blueprint = $left; Target = $right }
        }
    }
}
