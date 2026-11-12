<#
.SYNOPSIS
    Turns the workload picker of an export run into the comma list the export takes, such as AAD or AAD,Intune,EXO,Teams.
.DESCRIPTION
    The choice is Full (every workload whose Default is true in src\PolicyEngine\Data\Workloads.psd1, in that file's order) or the
    prefix of one workload in that list. Blank, and no PE_WORKLOAD in the environment, is Full. Anything else is an error.
#>
param
(
    [string]$Choice = $env:PE_WORKLOAD,

    [string]$WorkloadsPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\PolicyEngine\Data\Workloads.psd1')
)

$ErrorActionPreference = 'Stop'
$workloads = @((Import-PowerShellDataFile -LiteralPath $WorkloadsPath).Workloads)
if (-not $Choice) { $Choice = 'Full' }

if ($Choice -ceq 'Full') { return [string](@($workloads | Where-Object { $_.Default } | ForEach-Object { $_.Prefix }) -join ',') }
if (@($workloads | Where-Object { $_.Prefix -ceq $Choice }).Count -eq 1) { return [string]$Choice }

$allowed = @('Full') + @($workloads | ForEach-Object { $_.Prefix })
# The text is a pipeline parameter: only plain characters are repeated in the message.
$shown = if ($Choice -cmatch '\A[A-Za-z0-9]{1,20}\z') { $Choice } else { '(not a workload name)' }
throw "Workload '$shown' is not one of: $($allowed -join ', ')."
