<#
.SYNOPSIS
    Gives every registered replica tenant its own blueprint, a copy of the master blueprint's latest version.
.DESCRIPTION
    A tenant follows an ordered list of blueprints (master blueprint first, its own last). Installations that predate this
    have replicas that follow the master blueprint alone, so a Promote from such a replica is refused (it would change the
    master blueprint). This script calls Initialize-PETenantBlueprint for each replica that has no blueprint of its own yet:
    it creates blueprints\<slug> as version 1 and records Blueprints = master blueprint, <slug> on the tenant. A replica
    that already has its blueprint is skipped, so the script can be run again. The master tenant is not touched.
    Use -WhatIf first: it lists what would be created and writes nothing.
.EXAMPLE
    pwsh -NoProfile -File tools\Initialize-PETenantBlueprints.ps1 -MasterBlueprint prod -WhatIf
.EXAMPLE
    pwsh -NoProfile -File tools\Initialize-PETenantBlueprints.ps1 -MasterBlueprint prod
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    # The master blueprint (the one the GUI worker is started with).
    [Parameter(Mandatory)]
    [string]$MasterBlueprint,

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force

foreach ($tenant in @(Get-PETenant -DataRoot $DataRoot | Where-Object { $_.Role -eq 'Replica' }))
{
    $wanted = "$MasterBlueprint|$($tenant.Slug)"
    if ((@($tenant.Blueprints) -join '|') -eq $wanted)
    {
        [pscustomobject]@{ Slug = $tenant.Slug; Blueprint = $tenant.Slug; Action = 'Skipped' }
        continue
    }
    if ($PSCmdlet.ShouldProcess("tenant '$($tenant.Slug)'", "create blueprint '$($tenant.Slug)' from '$MasterBlueprint' and follow it"))
    {
        $name = Initialize-PETenantBlueprint -Slug $tenant.Slug -MasterBlueprint $MasterBlueprint -DataRoot $DataRoot
        [pscustomobject]@{ Slug = $tenant.Slug; Blueprint = $name; Action = 'Created' }
    }
    else
    {
        [pscustomobject]@{ Slug = $tenant.Slug; Blueprint = $tenant.Slug; Action = 'WouldCreate' }
    }
}
