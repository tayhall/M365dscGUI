function Get-PEScope
{
    <#
    .SYNOPSIS
    Reads the check scopes (scopes.json in the data root): named sets of resource types, optionally narrowed to keys
    that match wildcard patterns. Returns every scope, or the one named by -Name (throws when it does not exist).

    .DESCRIPTION
    A scope is how a client says "check these high-value things often": for example CA policies, or only the role
    groups among the groups. Invoke-PEScopeCheck exports just the scope's types and compares just the scope's items.
    Scope = @{ Name; Description; Types = @(<DSC resource names>); Keys = @(<-like patterns on the item key>) }. Empty
    Keys means every item of the types. Every DSC resource name is also a scope of its own (Get-PEScope -Name AADGroup),\n    unless a scope of the same name is defined, which then wins.
    #>
    [CmdletBinding()]
    param
    (
        [string]$Name,

        [string]$DataRoot
    )

    $raw = Read-PEJson -Path (Get-PEScopePath -DataRoot $DataRoot)
    $scopes = @(foreach ($entry in @($raw))
        {
            if ($null -eq $entry) { continue }
            [pscustomobject]@{
                Name        = [string]$entry.Name
                Description = [string]$entry.Description
                Types       = [string[]]@(@($entry.Types) | Where-Object { $_ })
                Keys        = [string[]]@(@($entry.Keys) | Where-Object { $_ })
            }
        })
    if (-not $PSBoundParameters.ContainsKey('Name'))
    {
        return $scopes
    }
    $match = @($scopes | Where-Object { $_.Name -ieq $Name })
    if ($match.Count -eq 0)
    {
        # Every DSC resource is a scope of its own (all its items, no key pattern): 'AADGroup', 'AADConditionalAccessPolicy', ...
        $type = @(Get-PEKnownResourceType | Where-Object { $_ -ieq $Name }) | Select-Object -First 1
        if ($type)
        {
            return [pscustomobject]@{ Name = [string]$type; Description = "Every $type"; Types = [string[]]@($type); Keys = [string[]]@() }
        }
        throw "Scope '$Name' not found. Defined: $(($scopes | ForEach-Object Name) -join ', '). Any DSC resource name (for example AADGroup) is also a scope."
    }
    return $match[0]
}

function Set-PEScope
{
    <#
    .SYNOPSIS
    Creates or replaces a scope. -Types are exact DSC resource names (for example AADConditionalAccessPolicy);
    -Keys are optional -like patterns on the item key (for example 'Role-*'). Returns the scope.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9_-]{0,40}\z')]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z][A-Za-z0-9]{2,80}\z')]
        [string[]]$Types,

        [string[]]$Keys = @(),

        [string]$Description = '',

        [string]$DataRoot
    )

    $existing = @(Get-PEScope -DataRoot $DataRoot | Where-Object { $_.Name -ine $Name })
    $scope = [pscustomobject]@{
        Name        = $Name
        Description = $Description
        Types       = [string[]]@($Types | Sort-Object -Unique)
        Keys        = [string[]]@($Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    Write-PEJson -Path (Get-PEScopePath -DataRoot $DataRoot) -InputObject @(@($existing) + $scope | Sort-Object Name)
    return $scope
}

function Remove-PEScope
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$DataRoot
    )

    $all = @(Get-PEScope -DataRoot $DataRoot)
    $kept = @($all | Where-Object { $_.Name -ine $Name })
    if ($kept.Count -ne $all.Count)
    {
        Write-PEJson -Path (Get-PEScopePath -DataRoot $DataRoot) -InputObject $kept
    }
}
