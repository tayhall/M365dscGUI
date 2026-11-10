<#
.SYNOPSIS
    Builds the self-describing name of an export run, for example 'Dev FULL AAD+Intune+EXO+Teams 2026-11-10'.
.DESCRIPTION
    <Environment> <FULL|PARTIAL> <workloads joined with +> <date>. FULL means the selection holds every workload whose Default is
    true in src\PolicyEngine\Data\Workloads.psd1; the workloads are listed in that file's order, not the order given.
#>
param
(
    [Parameter(Mandatory)]
    [string]$Environment,

    # DSC workload prefixes, comma separated.
    [Parameter(Mandatory)]
    [string]$Workloads,

    [datetime]$RunDate = [datetime]::UtcNow,

    [string]$WorkloadsPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\PolicyEngine\Data\Workloads.psd1')
)

$ErrorActionPreference = 'Stop'
$known = @((Import-PowerShellDataFile -LiteralPath $WorkloadsPath).Workloads)
$chosen = @($Workloads -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$selected = @($known | Where-Object { $chosen -contains $_.Prefix })
$missingDefault = @($known | Where-Object { $_.Default -and $chosen -notcontains $_.Prefix })
$scope = if ($missingDefault.Count -eq 0) { 'FULL' } else { 'PARTIAL' }

return "$Environment $scope $(@($selected.Prefix) -join '+') $($RunDate.ToUniversalTime().ToString('yyyy-MM-dd'))"
