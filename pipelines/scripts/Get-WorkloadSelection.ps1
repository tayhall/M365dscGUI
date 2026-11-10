<#
.SYNOPSIS
    Turns the ticked workload checkboxes of a pipeline run into a comma list such as AAD,Intune.
.DESCRIPTION
    Azure DevOps hands each checkbox to the script as an environment variable PE_WL_<Prefix> whose text is True when ticked.
    The workloads and their order come from src\PolicyEngine\Data\Workloads.psd1 (the engine's single list); variables for
    prefixes that are not in the list are ignored. Nothing ticked is an error unless -AllowNone (then an empty string).
#>
param
(
    [switch]$AllowNone,

    [string]$WorkloadsPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\PolicyEngine\Data\Workloads.psd1')
)

$ErrorActionPreference = 'Stop'
$workloads = @((Import-PowerShellDataFile -LiteralPath $WorkloadsPath).Workloads)

$ticked = @(foreach ($workload in $workloads)
    {
        $value = [Environment]::GetEnvironmentVariable("PE_WL_$($workload.Prefix)")
        if ($value -and $value.Trim() -ieq 'True') { $workload.Prefix }
    })

if ($ticked.Count -eq 0 -and -not $AllowNone)
{
    throw 'No workload is ticked. Tick at least one workload.'
}
return [string]($ticked -join ',')
