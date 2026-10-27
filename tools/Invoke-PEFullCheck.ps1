<#
.SYNOPSIS
    Exports the tenant and compares it with a blueprint (a full check). Writes data\checks\<CheckId>\result.json.
.DESCRIPTION
    Thin wrapper over Invoke-PEFullCheck in the PolicyEngine module. The export (export.ps1 and export.log) goes to
    data\exports\<CheckId>. Failed components are reported as NotChecked, never as Missing.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PEFullCheck.ps1 -BlueprintName test
#>
param
(
    [Parameter(Mandatory)]
    [string]$BlueprintName,

    [string[]]$Workloads,

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$arguments = @{ BlueprintName = $BlueprintName }
if ($Workloads)
{
    $arguments.Workloads = $Workloads
}
if ($DataRoot)
{
    $arguments.DataRoot = $DataRoot
}
$result = Invoke-PEFullCheck @arguments

"Check $($result.CheckId): $(@($result.Findings).Count) findings, $(@($result.State.NotChecked).Count) types not checked"
$result.Findings | Group-Object Kind | Sort-Object Name | ForEach-Object { '  {0}: {1}' -f $_.Name, $_.Count }
