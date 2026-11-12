<#
.SYNOPSIS
    Compares a tenant's previous export with its latest export and builds the report and the revert and promote configurations. The whole
    tenant-changes step.
.DESCRIPTION
    The tenant's identifiers come from pipelines\config\<Tenant>.psd1. When that file has a Writer app (Dev), the revert configuration is
    compiled to MOF with the Writer certificate's thumbprint read from Key Vault (nothing is imported); a tenant with no Writer app
    (PreProd) gets the report and the configuration text only. The comparison itself is tools\Invoke-PETenantChanges.ps1. The run is
    renamed to what it compared. Run it from an AzurePowerShell task.
#>
param
(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'PreProd')]
    [string]$Tenant,

    [Parameter(Mandatory)]
    [string]$PreviousExportPath,

    [Parameter(Mandatory)]
    [string]$LatestExportPath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,12}\z')]
    [string]$PreviousRun,

    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,12}\z')]
    [string]$LatestRun,

    [Parameter(Mandatory)]
    [ValidatePattern('\A[\w .()-]{1,40}\z')]
    [string]$PreviousName,

    [Parameter(Mandatory)]
    [ValidatePattern('\A[\w .()-]{1,40}\z')]
    [string]$LatestName,

    # Which export series was compared: Full or one workload. Only that workload is compared, so a component that was not exported is not
    # reported as unchecked.
    [string]$Workload = 'Full',

    # For tests: another config folder, the tool and the certificate script.
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config'),
    [string]$ToolPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools\Invoke-PETenantChanges.ps1'),
    [string]$ConnectScript = (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1')
)

$ErrorActionPreference = 'Stop'
$config = & (Join-Path $PSScriptRoot 'Get-PipelineConfig.ps1') -Environment $Tenant -Require TenantDomain -ConfigPath $ConfigPath
$completeWorkloads = & (Join-Path $PSScriptRoot 'Resolve-WorkloadChoice.ps1') -Choice $Workload

$arguments = @{
    Tenant = $Tenant; PreviousExportPath = $PreviousExportPath; LatestExportPath = $LatestExportPath; TargetTenantDomain = $config.TenantDomain
    OutputPath = $OutputPath; PreviousRun = $PreviousRun; LatestRun = $LatestRun; PreviousName = $PreviousName; LatestName = $LatestName
    CompleteWorkload = $completeWorkloads
}
# Compile the revert only for a tenant with a real Writer app and organization name (a CHANGE-ME value is the unfilled example).
$hasWriter = $config.WriterAppId -and $config.WriterAppId -notmatch 'CHANGE-ME' -and $config.OrganizationName -and $config.OrganizationName -notmatch 'CHANGE-ME'
if ($hasWriter)
{
    $thumbprint = & $ConnectScript -Environment $Tenant -Role Writer -ThumbprintOnly
    $arguments += @{ ApplicationId = $config.WriterAppId; OrganizationName = $config.OrganizationName; CertificateThumbprint = $thumbprint }
}
else { "$Tenant has no Writer app in its config: the report and the configuration text are written, the revert is not compiled." }

& $ToolPath @arguments

# The run states what it compared ('>' is not allowed in a run name).
Write-Host "##vso[build.updatebuildnumber]$Tenant $Workload changes $PreviousName to $LatestName"
$summary = Get-Content -LiteralPath (Join-Path $OutputPath 'summary.json') -Raw | ConvertFrom-Json
Write-Host "##vso[task.logissue type=warning]Changes: $($summary.Revert.OpenFindings) open ($($summary.Revert.ByKind)); $($summary.Revert.Manual) item(s) need manual action."
