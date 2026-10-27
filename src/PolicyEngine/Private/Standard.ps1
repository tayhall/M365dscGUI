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
