<#
.SYNOPSIS
    Compares the PreProd export with the Dev export and builds the drift report, configurations and MOF files. The whole compare step.
.DESCRIPTION
    Dev's identifiers come from pipelines\config\Dev.psd1; the Writer certificate's thumbprint is read from Key Vault (nothing is imported)
    and compiled into the MOFs. The comparison itself is tools\Invoke-PEPipelineCompare.ps1. Run it from an AzurePowerShell task.
#>
param
(
    [Parameter(Mandatory)]
    [string]$SourceExportPath,

    [Parameter(Mandatory)]
    [string]$TargetExportPath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [ValidateSet('Combined', 'PerWorkload')]
    [string]$MofLayout = 'Combined',

    # Workloads whose Dev export is complete, comma separated, for example AAD,Intune,EXO,Teams.
    [ValidatePattern('\A[A-Za-z0-9,]*\z')]
    [string]$CompleteWorkloads = 'AAD,Intune,EXO,Teams'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dev = & (Join-Path $PSScriptRoot 'Get-PipelineConfig.ps1') -Environment Dev -Require TenantDomain, OrganizationName, WriterAppId
$thumbprint = & (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1') -Environment Dev -Role Writer -ThumbprintOnly

& (Join-Path $repoRoot 'tools\Invoke-PEPipelineCompare.ps1') `
    -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath -OutputPath $OutputPath `
    -TargetTenantDomain $dev.TenantDomain -CompleteWorkload $CompleteWorkloads -MofLayout $MofLayout `
    -Compile -ApplicationId $dev.WriterAppId -CertificateThumbprint $thumbprint -OrganizationName $dev.OrganizationName

$summary = Get-Content (Join-Path $OutputPath 'summary.json') -Raw | ConvertFrom-Json
Write-Host "##vso[task.logissue type=warning]Drift: $($summary.OpenFindings) open ($($summary.ByKind)); $($summary.Manual) item(s) need manual action."
