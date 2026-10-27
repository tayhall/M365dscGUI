<#
.SYNOPSIS
    Checks one scope (a named set of resource types, optionally only matching keys) against a blueprint.
.DESCRIPTION
    Thin wrapper over Invoke-PEScopeCheck in the PolicyEngine module. Exports only the scope's types with the Reader app
    and folds the result into the latest Full check. A Full check must exist first. Define scopes with Set-PEScope.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PEScopeCheck.ps1 -BlueprintName test -Scope ca-policies
#>
param
(
    [Parameter(Mandatory)]
    [string]$BlueprintName,

    [Parameter(Mandatory)]
    [string]$Scope,

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$arguments = @{ BlueprintName = $BlueprintName; Scope = $Scope }
if ($DataRoot)
{
    $arguments.DataRoot = $DataRoot
}
$result = Invoke-PEScopeCheck @arguments

"Scope '$($result.Scope)' (check $($result.CheckId)): $($result.Items) blueprint items, $($result.Drifted) drifted, $($result.NotChecked) types not checked"
$result.Findings | Group-Object Kind | Sort-Object Name | ForEach-Object { '  {0}: {1}' -f $_.Name, $_.Count }
