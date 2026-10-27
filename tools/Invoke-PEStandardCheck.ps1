<#
.SYNOPSIS
    Compares a tenant's blueprint with a standard. Writes data\checks\<CheckId>\result.json (Kind Standard).
.DESCRIPTION
    Thin wrapper over Invoke-PEStandardCheck in the PolicyEngine module. A tenant is managed against its blueprint, so the question is
    whether that blueprint meets the standard: nothing is read from the tenant, and it works for an offline tenant. Only what the standard
    states is compared. The summary says how many settings were compared out of how many the standard holds, and what was left out (not
    covered because of a placeholder or an unknown property, or no data for the type in the blueprint). Accepted risks show as Accepted.
    To close a difference: Copy-PEStandardItem copies the standard's setting into the blueprint, then revert the tenant to its blueprint.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PEStandardCheck.ps1 -StandardName asd -BlueprintName demo
#>
param
(
    [Parameter(Mandatory)]
    [string]$StandardName,

    # The master blueprint (a tenant with no blueprint of its own follows it).
    [Parameter(Mandatory)]
    [string]$BlueprintName,

    [string]$Tenant = 'master',

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$arguments = @{ StandardName = $StandardName; BlueprintName = $BlueprintName; Tenant = $Tenant }
if ($DataRoot)
{
    $arguments.DataRoot = $DataRoot
}
$result = Invoke-PEStandardCheck @arguments
$coverage = $result.Coverage
$notCovered = @($coverage.NotCovered.Values | Measure-Object -Sum).Sum

"Check $($result.CheckId): compared $($coverage.Checked) of $($coverage.Total) settings with blueprint '$($result.BlueprintName)' v$($result.BlueprintVersion) ($notCovered not covered, $($coverage.NotReadable) with no data in the blueprint)"
$result.Findings | Group-Object Kind | Sort-Object Name | ForEach-Object { '  {0}: {1}' -f $_.Name, $_.Count }
$accepted = @($result.Findings | Where-Object State -EQ 'Accepted').Count
if ($accepted -gt 0)
{
    "  accepted risks: $accepted"
}
