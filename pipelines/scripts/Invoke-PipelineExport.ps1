<#
.SYNOPSIS
    Exports one tenant (config from pipelines\config\<Environment>.psd1) into -OutputPath. The whole export pipeline step.
.DESCRIPTION
    Imports the Reader certificate from Key Vault, runs tools\Export-M365DscTenant.ps1, and always removes the certificate again.
    Run it from an AzurePowerShell task (already signed in to Azure).
#>
param
(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'PreProd')]
    [string]$Environment,

    # DSC workload prefixes, comma separated, for example AAD,Intune,EXO,Teams.
    # Not given: the ticked workload checkboxes (PE_WL_<Prefix>) are used.
    [ValidatePattern('\A[A-Za-z0-9,]*\z')]
    [string]$Workloads,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$slug = $Environment.ToLowerInvariant()

# Nothing may be imported or connected when there is nothing to export, so the list is settled first (a typed list wins).
if (-not $Workloads)
{
    $Workloads = & (Join-Path $PSScriptRoot 'Get-WorkloadSelection.ps1')
}

# Name the Azure DevOps run after what it exports (Compare's run picker shows it). A local run stays quiet.
# The name is cosmetic: a failure to build it only warns and never stops the export.
if ($env:TF_BUILD -eq 'True')
{
    try
    {
        $runName = & (Join-Path $PSScriptRoot 'Get-ExportRunName.ps1') -Environment $Environment -Workloads $Workloads
        Write-Output "##vso[build.updatebuildnumber]$runName"
    }
    catch
    {
        Write-Warning "Run name not set: $($_.Exception.Message)"
    }
}

try
{
    & (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1') -Environment $Environment -Role Reader
    & (Join-Path $repoRoot 'tools\Export-M365DscTenant.ps1') -Role Reader -Tenant $slug -Workloads $Workloads -OutputPath $OutputPath
}
finally
{
    & (Join-Path $PSScriptRoot 'Disconnect-PipelineTenant.ps1') -Slug $slug -Role Reader
}
