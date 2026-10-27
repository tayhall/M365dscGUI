<#
.SYNOPSIS
    Creates version 1 of a blueprint from an existing full export folder (export.ps1 + export.log).
.DESCRIPTION
    Thin wrapper over New-PEStateFromExport and Initialize-PEBlueprint in the PolicyEngine module. Take the export with
    tools\Export-M365DscTenant.ps1 (Reader app) first; components that the export log reports as failed become the
    blueprint's NotChecked list. Refuses if the blueprint already exists (use Approve-PEBlueprintChange for new versions).
.EXAMPLE
    pwsh -NoProfile -File tools\Export-M365DscTenant.ps1 -OutputPath data\exports\blueprint-test
    pwsh -NoProfile -File tools\New-PEBlueprint.ps1 -Name test -ExportPath data\exports\blueprint-test
#>
param
(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$ExportPath,

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$state = New-PEStateFromExport -Path (Resolve-Path -LiteralPath $ExportPath).ProviderPath -WarningAction SilentlyContinue
$arguments = @{ Name = $Name; State = $state }
if ($DataRoot)
{
    $arguments.DataRoot = $DataRoot
}
$version = Initialize-PEBlueprint @arguments

"Blueprint '$Name' version ${version}:$(@($state.Records).Count) records, $(@($state.NotChecked).Count) types not checked"
$state.Records | Group-Object Workload | Sort-Object Name | ForEach-Object { '  {0}: {1} records' -f $_.Name, $_.Count }
if (@($state.NotChecked).Count -gt 0)
{
    'Not checked:'
    $state.NotChecked | Sort-Object ResourceType | ForEach-Object { '  {0}: {1}' -f $_.ResourceType, $_.Reason }
}
if (@($state.Meta.LogWarnings).Count -gt 0)
{
    "Export log warnings: $(@($state.Meta.LogWarnings).Count)"
    $state.Meta.LogWarnings | ForEach-Object { "  $_" }
}
