<#
.SYNOPSIS
    Builds drift-report.html: the PreProd export against the Dev export, as one self-contained page in which a reviewer ticks the items to apply.
.DESCRIPTION
    Built for pipelines (no GUI, no worker, nothing is sent anywhere). Thin wrapper over the PolicyEngine module: Invoke-PEExportComparison
    (the engine's comparison, the same one tools\Invoke-PEPipelineCompare.ps1 uses), Get-PEExportFingerprint, Get-PEDriftReportData and
    New-PEDriftReportHtml. The page lets a reviewer tick individual items and download approved.json, the approved list that the approved-apply
    pipeline reads. Writes only -OutputPath\drift-report.html; the comparison's scratch folder is removed.
.EXAMPLE
    pwsh -NoProfile -File tools\New-PEDriftReport.ps1 -SourceExportPath preprod -TargetExportPath dev -TargetTenantDomain contoso-dev.onmicrosoft.com -OutputPath out -SourceRun 1201 -TargetRun 1202
#>
param
(
    # Folders holding export.ps1 (and export.log): PreProd (what Dev should look like) and Dev.
    [Parameter(Mandatory)]
    [string]$SourceExportPath,

    [Parameter(Mandatory)]
    [string]$TargetExportPath,

    # Dev's domain, for example contoso-dev.onmicrosoft.com (differences that are only the tenant's own name are ignored).
    [Parameter(Mandatory)]
    [string]$TargetTenantDomain,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    # The Azure DevOps run ids of the two export runs, recorded in the approved list so Apply can fetch the very same exports.
    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,12}\z')]
    [string]$SourceRun,

    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,12}\z')]
    [string]$TargetRun,

    # The tenant slug written into the approved list (lowercase letters, digits, hyphen), and plain-text names for the two sides in the page.
    [ValidatePattern('\A[a-z0-9][a-z0-9-]{0,39}\z')]
    [string]$Tenant = 'dev',

    [ValidatePattern('\A[\w .()-]{1,40}\z')]
    [string]$SourceLabel = 'PreProd',

    [ValidatePattern('\A[\w .()-]{1,40}\z')]
    [string]$TargetLabel = 'Dev',

    # Workload prefixes (Data\Workloads.psd1) whose Dev export is complete, so an empty type there is really empty.
    [string[]]$CompleteWorkload = @('AAD', 'Intune', 'EXO', 'Teams')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

foreach ($path in $SourceExportPath, $TargetExportPath)
{
    if (-not (Test-Path -LiteralPath (Join-Path $path 'export.ps1'))) { throw "No export.ps1 in $path" }
}
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
$report = Join-Path $OutputPath 'drift-report.html'
if (Test-Path -LiteralPath $report) { throw "$report already exists; it is not overwritten." }

$work = Join-Path $OutputPath ('.report-work-' + [guid]::NewGuid().ToString('N'))
try
{
    $comparison = Invoke-PEExportComparison -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath `
        -TargetTenantDomain $TargetTenantDomain -DataRoot $work -CompleteWorkload $CompleteWorkload -WarningAction SilentlyContinue

    $targetState = New-PEStateFromExport -Path (Resolve-Path -LiteralPath $TargetExportPath).ProviderPath -AllowMissingLog -WarningAction SilentlyContinue
    $source = @{ Run = $SourceRun; ExportedAt = [string]$comparison.SourceState.Meta.ExportedAt; Fingerprint = (Get-PEExportFingerprint -Path $SourceExportPath) }
    $target = @{ Run = $TargetRun; ExportedAt = [string]$targetState.Meta.ExportedAt; Fingerprint = (Get-PEExportFingerprint -Path $TargetExportPath) }

    $data = Get-PEDriftReportData -Comparison $comparison -Tenant $Tenant -Source $source -Target $target -SourceLabel $SourceLabel -TargetLabel $TargetLabel
    New-PEDriftReportHtml -Data $data -Path $report -Title "Drift report: $SourceLabel to $TargetLabel" | Out-Null
    $approvable = @($data.Items | Where-Object Approvable).Count
    "Drift report: $(@($data.Items).Count) items, $approvable approvable ($report)"
}
finally
{
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
