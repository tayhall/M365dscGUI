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
    [Parameter(Mandatory)]
    [ValidatePattern('\A[A-Za-z0-9,]+\z')]
    [string]$Workloads,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$slug = $Environment.ToLowerInvariant()

try
{
    & (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1') -Environment $Environment -Role Reader
    & (Join-Path $repoRoot 'tools\Export-M365DscTenant.ps1') -Role Reader -Tenant $slug -Workloads $Workloads -OutputPath $OutputPath
}
finally
{
    & (Join-Path $PSScriptRoot 'Disconnect-PipelineTenant.ps1') -Slug $slug -Role Reader
}
