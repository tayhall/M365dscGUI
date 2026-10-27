<#
.SYNOPSIS
    Checks a tenant against a standard. Writes data\checks\<CheckId>\result.json (Kind Standard).
.DESCRIPTION
    Thin wrapper over Invoke-PEStandardCheck in the PolicyEngine module. Only the workloads the standard covers are exported, and only what
    the standard states is compared. The summary says how many settings were checked out of how many the standard holds, and what was left
    out (not covered because of a placeholder or an unknown property, or not readable in this tenant). Accepted risks show as Accepted.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PEStandardCheck.ps1 -StandardName asd
#>
param
(
    [Parameter(Mandatory)]
    [string]$StandardName,

    [string]$Tenant = 'master',

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$arguments = @{ StandardName = $StandardName; Tenant = $Tenant }
if ($DataRoot)
{
    $arguments.DataRoot = $DataRoot
}
$result = Invoke-PEStandardCheck @arguments
$coverage = $result.Coverage
$notCovered = @($coverage.NotCovered.Values | Measure-Object -Sum).Sum

"Check $($result.CheckId): checked $($coverage.Checked) of $($coverage.Total) settings ($notCovered not covered, $($coverage.NotReadable) not readable in this tenant)"
$result.Findings | Group-Object Kind | Sort-Object Name | ForEach-Object { '  {0}: {1}' -f $_.Name, $_.Count }
$accepted = @($result.Findings | Where-Object State -EQ 'Accepted').Count
if ($accepted -gt 0)
{
    "  accepted risks: $accepted"
}
