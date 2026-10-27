function Get-PETenant
{
    <#
    .SYNOPSIS
    The tenants this installation works with (tenants.json in the data root): one Master and any number of Replicas.

    .DESCRIPTION
    Every tenant has a Slug (the name used everywhere: -Tenant, the GUI, the app registration folder), a Role, a
    DisplayName, the TenantId its apps belong to and Blueprints (the blueprints it follows, master blueprint first; empty
    means the master blueprint alone). The Master is the tenant the blueprint is taken from and its apps
    are the ones the registration tool has always written. A Replica is compared with the same blueprint and is brought
    into line with it. When tenants.json does not exist, or has no Master, the Master is read from the Reader app file
    so an installation that predates tenants keeps working. -Slug returns one tenant (throws when unknown).
    #>
    [CmdletBinding()]
    param
    (
        [string]$Slug,

        [string]$DataRoot
    )

    $raw = Read-PEJson -Path (Get-PETenantPath -DataRoot $DataRoot)
    $tenants = @(foreach ($entry in @($raw))
        {
            if ($null -eq $entry) { continue }
            [pscustomobject]@{ Slug = [string]$entry.Slug; Role = [string]$entry.Role; DisplayName = [string]$entry.DisplayName; TenantId = [string]$entry.TenantId; Blueprints = @($entry.Blueprints | Where-Object { $_ } | ForEach-Object { [string]$_ }); Offline = [bool]$entry.Offline }
        })
    if (@($tenants | Where-Object { $_.Slug -eq 'master' }).Count -eq 0)
    {
        $id = Get-PEReaderTenantId
        $tenants = @([pscustomobject]@{ Slug = 'master'; Role = 'Master'; DisplayName = $(if ($id) { $id } else { 'master' }); TenantId = [string]$id; Blueprints = @(); Offline = $false }) + $tenants
    }
    if (-not $PSBoundParameters.ContainsKey('Slug'))
    {
        return $tenants
    }
    $match = @($tenants | Where-Object { $_.Slug -ceq $Slug })
    if ($match.Count -eq 0)
    {
        throw "Tenant '$Slug' is not registered. Registered: $(($tenants | ForEach-Object Slug) -join ', ')."
    }
    return $match[0]
}

function Set-PETenant
{
    <#
    .SYNOPSIS
    Registers (or updates) a tenant. The tenant 'master' is always the Master; any other slug is a Replica.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Slug,

        [string]$DisplayName,

        [string]$TenantId,

        [string[]]$Blueprints,

        # An offline tenant is known only through export files that are uploaded for it; nothing connects to it.
        [switch]$Offline,

        [string]$DataRoot
    )

    if ($Offline -and $Slug -eq 'master')
    {
        throw 'The master tenant cannot be offline.'
    }
    $existing = @(Get-PETenant -DataRoot $DataRoot | Where-Object { $_.Slug -ne $Slug })
    $current = @(Get-PETenant -DataRoot $DataRoot | Where-Object { $_.Slug -eq $Slug })
    $entry = [pscustomobject]@{
        Slug        = $Slug
        Role        = $(if ($Slug -eq 'master') { 'Master' } else { 'Replica' })
        DisplayName = $(if ($DisplayName) { $DisplayName } elseif ($current.Count) { $current[0].DisplayName } else { $Slug })
        TenantId    = $(if ($TenantId) { $TenantId } elseif ($current.Count) { $current[0].TenantId } else { '' })
        Blueprints  = @($(if ($PSBoundParameters.ContainsKey('Blueprints')) { $Blueprints } elseif ($current.Count) { $current[0].Blueprints }))
        Offline     = $(if ($PSBoundParameters.ContainsKey('Offline')) { [bool]$Offline } elseif ($current.Count) { [bool]$current[0].Offline } else { $false })
    }
    $all = @(@($existing) + $entry | Sort-Object { if ($_.Slug -eq 'master') { '' } else { $_.Slug } })
    Write-PEJson -Path (Get-PETenantPath -DataRoot $DataRoot) -InputObject $all
    return $entry
}

function Remove-PETenant
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Slug,

        [string]$DataRoot
    )

    if ($Slug -eq 'master')
    {
        throw 'The master tenant cannot be removed.'
    }
    $all = @(Get-PETenant -DataRoot $DataRoot)
    $kept = @($all | Where-Object { $_.Slug -ne $Slug })
    if ($kept.Count -ne $all.Count)
    {
        Write-PEJson -Path (Get-PETenantPath -DataRoot $DataRoot) -InputObject $kept
    }
}
