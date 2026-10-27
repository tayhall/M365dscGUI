<#
.SYNOPSIS
    Round-trip classifier: for each resource type of a blueprint, does DSC's own Test accept the configuration a Revert would send?
.DESCRIPTION
    See Invoke-PERoundTrip. The Test goes through the Local Configuration Manager, so run it from an ELEVATED PowerShell 7 console;
    nothing in the tenant is changed (Reader app, test only). -RenderOnly only builds the configurations and needs no elevation.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PERoundTrip.ps1 -BlueprintName demo -RenderOnly
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PERoundTrip.ps1 -BlueprintName demo -Type AADGroup,AADEntitlementManagementAccessPackage
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)]
    [string]$BlueprintName,

    [string]$Tenant = 'master',

    [string[]]$Type,

    [ValidateRange(1, 20)]
    [int]$PerType = 1,

    [ValidateRange(1, 200)]
    [int]$ChunkSize = 25,

    [switch]$RenderOnly,

    [string]$DataRoot
)

Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -ErrorAction Stop
$arguments = @{ BlueprintName = $BlueprintName; Tenant = $Tenant; PerType = $PerType; ChunkSize = $ChunkSize; RenderOnly = $RenderOnly }
# From pwsh -File a list arrives as one string: -Type AADGroup,TeamsMeetingPolicy (no space after the comma).
$Type = @($Type | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Type.Count -gt 0) { $arguments.Type = $Type }
if ($DataRoot) { $arguments.DataRoot = $DataRoot }
$list = @(Invoke-PERoundTrip @arguments -WarningAction SilentlyContinue)
''
$list | Group-Object Class | Sort-Object Name | ForEach-Object { '{0,-13} {1,4} type(s)' -f $_.Name, $_.Count }
# The same LCM error repeated for many types is one problem: show each distinct message once, with the types it hit.
$errors = @($list | Where-Object { $_.Class -eq 'TestError' } | Group-Object { ([string]$_.Detail -replace '\s+', ' ') })
if ($errors.Count -gt 0)
{
    ''
    'Test errors (each distinct message once):'
    foreach ($group in $errors | Sort-Object Count -Descending)
    {
        '  [{0} type(s), e.g. {1}] {2}' -f $group.Count, $group.Group[0].ResourceType, $group.Name.Substring(0, [Math]::Min(400, $group.Name.Length))
    }
}
''
$list | Where-Object { $_.Class -notin 'Reliable', 'Rendered', 'TestError' } | ForEach-Object {
    '{0,-12} {1,-58} {2}' -f $_.Class, $_.ResourceType, $(if ($_.Detail) { ([string]$_.Detail -replace '\s+', ' ').Substring(0, [Math]::Min(100, ([string]$_.Detail -replace '\s+', ' ').Length)) } else { "$($_.InDesiredState) in desired state, $($_.WouldChange) would change" })
}
