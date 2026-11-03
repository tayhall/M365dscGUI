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
    [string]$CompleteWorkloads = 'AAD,Intune,EXO,Teams',

    # Names of the two export runs this comparison used, recorded in summary.json so Apply can show them.
    [ValidatePattern('\A[\w .#()-]{0,100}\z')]
    [string]$PreProdRun = '',

    [ValidatePattern('\A[\w .#()-]{0,100}\z')]
    [string]$DevRun = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dev = & (Join-Path $PSScriptRoot 'Get-PipelineConfig.ps1') -Environment Dev -Require TenantDomain, OrganizationName, WriterAppId
$thumbprint = & (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1') -Environment Dev -Role Writer -ThumbprintOnly

& (Join-Path $repoRoot 'tools\Invoke-PEPipelineCompare.ps1') `
    -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath -OutputPath $OutputPath `
    -TargetTenantDomain $dev.TenantDomain -CompleteWorkload $CompleteWorkloads -MofLayout $MofLayout `
    -Compile -ApplicationId $dev.WriterAppId -CertificateThumbprint $thumbprint -OrganizationName $dev.OrganizationName

$summaryPath = Join-Path $OutputPath 'summary.json'
$summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
$summary | Add-Member -NotePropertyName GeneratedAtUtc -NotePropertyValue ([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm')) -Force
$summary | Add-Member -NotePropertyName PreProdExportRun -NotePropertyValue $(if ($PreProdRun) { $PreProdRun } else { '(unknown)' }) -Force
$summary | Add-Member -NotePropertyName DevExportRun -NotePropertyValue $(if ($DevRun) { $DevRun } else { '(unknown)' }) -Force
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

# The HTML drift report: tick the items to apply, download approved.json. It records the two export run ids so Apply can fetch the very same
# exports, so without numeric run ids (a manual run outside the pipeline) it is not built.
if ($PreProdRun -match '\A\d{1,12}\z' -and $DevRun -match '\A\d{1,12}\z')
{
    & (Join-Path $repoRoot 'tools\New-PEDriftReport.ps1') `
        -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath -OutputPath $OutputPath `
        -TargetTenantDomain $dev.TenantDomain -CompleteWorkload $CompleteWorkloads -SourceRun $PreProdRun -TargetRun $DevRun
}
else
{
    Write-Host 'The export run ids are not numeric, so drift-report.html was not built (it needs them to pin the exports).'
}
Write-Host "##vso[task.logissue type=warning]Drift: $($summary.OpenFindings) open ($($summary.ByKind)); $($summary.Manual) item(s) need manual action."
