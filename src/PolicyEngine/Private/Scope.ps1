function Get-PEScopePath
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [string]$DataRoot
    )

    return Join-Path (Get-PEDataRoot -Override $DataRoot) 'scopes.json'
}

function Test-PEInScope
{
    # True when an item (type and key) belongs to the scope: its type is listed and, when the scope has key patterns, the
    # key matches one (case-insensitive wildcard). An item without a key (NotChecked, Unkeyed) belongs by type alone.
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        $Scope,

        [AllowNull()]
        [string]$ResourceType,

        [AllowNull()]
        [string]$Key
    )

    if ($null -eq $ResourceType -or @($Scope.Types | Where-Object { $_ -ieq $ResourceType }).Count -eq 0)
    {
        return $false
    }
    $patterns = @($Scope.Keys | Where-Object { $_ })
    if ($patterns.Count -eq 0 -or [string]::IsNullOrEmpty($Key))
    {
        return $true
    }
    foreach ($pattern in $patterns)
    {
        if ($Key -like $pattern) { return $true }
    }
    return $false
}

function Get-PEKnownResourceType
{
    # Every resource type the pinned Microsoft365DSC module knows (its ResourcePermissions.json, the list its own export
    # uses), so every DSC resource is a ready-made scope without being defined. Empty when the module is not installed.
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    if ($null -eq $script:PEKnownResourceTypes)
    {
        $names = @()
        try
        {
            $file = Get-PEDscModuleFile -Name ResourcePermissions.json
            $names = @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object)
        }
        catch
        {
            $names = @()
        }
        if ($names.Count -eq 0) { return [string[]]@() }
        $script:PEKnownResourceTypes = [string[]]$names
    }
    return $script:PEKnownResourceTypes
}
