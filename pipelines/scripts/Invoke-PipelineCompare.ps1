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
    # Not given: the ticked workload checkboxes (PE_WL_<Prefix>) when the pipeline passes them, else this default.
    [ValidatePattern('\A[A-Za-z0-9,]*\z')]
    [string]$CompleteWorkloads = 'AAD,Intune,EXO,Teams',

    # Names of the two export runs this comparison used, recorded in summary.json so Apply can show them.
    [Alias('SourceRun')]
    [ValidatePattern('\A[\w .#()-]{0,100}\z')]
    [string]$PreProdRun = '',

    [Alias('TargetRun')]
    [ValidatePattern('\A[\w .#()-]{0,100}\z')]
    [string]$DevRun = '',

    # The two tenants compared. Only PreProd to Dev (the default) builds MOF files and an approvable report; any other pair gives the
    # comparison as a read-only report (nothing could be applied) and reads no certificate.
    [ValidateSet('Dev', 'PreProd', 'Prod')]
    [string]$SourceTenant = 'PreProd',

    [ValidateSet('Dev', 'PreProd', 'Prod')]
    [string]$TargetTenant = 'Dev',

    # Which export series was compared: Full, or one workload prefix (AAD, Intune, EXO, Teams, SC). A single workload is the only complete one
    # (the ticked boxes are ignored), because an export of one workload says nothing about the others.
    [ValidatePattern('\A[A-Za-z0-9]{1,20}\z')]
    [string]$Workload = 'Full',

    # Test hooks (refused unless PE_TEST_HOOKS is 1, which the pipeline never sets): the config folder and the scripts that touch tenants.
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config'),
    [string]$ConnectScript = (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1'),
    [string]$CompareTool = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools\Invoke-PEPipelineCompare.ps1'),
    [string]$ReportTool = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools\New-PEDriftReport.ps1')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$usedHooks = @('ConfigPath', 'ConnectScript', 'CompareTool', 'ReportTool' | Where-Object { $PSBoundParameters.ContainsKey($_) })
if ($usedHooks.Count -gt 0 -and $env:PE_TEST_HOOKS -ne '1')
{
    throw "The parameter(s) $($usedHooks -join ', ') are test hooks and are only accepted when PE_TEST_HOOKS is 1. Nothing was done."
}
if ($SourceTenant -eq $TargetTenant)
{
    throw "Compare needs two different tenants (both are $SourceTenant). To see what changed in one tenant between two of its own exports, use the Tenant changes pipeline."
}

# The pipeline passes one PE_WL_<Prefix> variable per workload: then the ticked boxes are the complete workloads, and no box ticked
# means nothing is complete. With no such variable at all (a manual run) the parameter's default stays.
$anyBox = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'PE_WL_*' }).Count -gt 0
if ($Workload -cne 'Full' -and -not $PSBoundParameters.ContainsKey('CompleteWorkloads'))
{
    $CompleteWorkloads = $Workload
}
elseif (-not $PSBoundParameters.ContainsKey('CompleteWorkloads') -and $anyBox)
{
    $CompleteWorkloads = & (Join-Path $PSScriptRoot 'Get-WorkloadSelection.ps1') -AllowNone
}

if (-not ($SourceTenant -eq 'PreProd' -and $TargetTenant -eq 'Dev'))
{
    # Any other pair: the comparison as a read-only report. No certificate, no MOF files, no approved list (nothing could be applied).
    $targetConfig = & (Join-Path $PSScriptRoot 'Get-PipelineConfig.ps1') -Environment $TargetTenant -Require TenantDomain -ConfigPath $ConfigPath
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    [ordered]@{
        SourceTenant = $SourceTenant; TargetTenant = $TargetTenant; ReadOnly = $true; Workload = $Workload
        SourceExportRun = $(if ($PreProdRun) { $PreProdRun } else { '(unknown)' }); TargetExportRun = $(if ($DevRun) { $DevRun } else { '(unknown)' })
        GeneratedAtUtc = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputPath 'summary.json') -Encoding utf8
    if ($PreProdRun -match '\A\d{1,12}\z' -and $DevRun -match '\A\d{1,12}\z')
    {
        try
        {
            & $ReportTool -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath -OutputPath $OutputPath `
                -TargetTenantDomain $targetConfig.TenantDomain -CompleteWorkload $CompleteWorkloads -SourceRun $PreProdRun -TargetRun $DevRun `
                -Tenant $TargetTenant.ToLowerInvariant() -SourceLabel $SourceTenant -TargetLabel $TargetTenant `
                -ReadOnlyReason "Read-only comparison: only PreProd to Dev can be applied (this is $SourceTenant to $TargetTenant)."
        }
        catch
        {
            $reason = (([string]$_.Exception.Message) -split "`r?`n")[0]
            Write-Host "##vso[task.logissue type=warning]drift-report.html was not built: $reason"
        }
    }
    else { Write-Host 'The export run ids are not numeric, so drift-report.html was not built.' }
    "Compared $SourceTenant with ${TargetTenant}: report only (nothing here can be applied)."
    return
}

$dev = & (Join-Path $PSScriptRoot 'Get-PipelineConfig.ps1') -Environment Dev -Require TenantDomain, OrganizationName, WriterAppId -ConfigPath $ConfigPath
$thumbprint = & $ConnectScript -Environment Dev -Role Writer -ThumbprintOnly

& $CompareTool `
    -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath -OutputPath $OutputPath `
    -TargetTenantDomain $dev.TenantDomain -CompleteWorkload $CompleteWorkloads -MofLayout $MofLayout `
    -Compile -ApplicationId $dev.WriterAppId -CertificateThumbprint $thumbprint -OrganizationName $dev.OrganizationName

$summaryPath = Join-Path $OutputPath 'summary.json'
$summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
$summary | Add-Member -NotePropertyName GeneratedAtUtc -NotePropertyValue ([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm')) -Force
$summary | Add-Member -NotePropertyName Workload -NotePropertyValue $Workload -Force
$summary | Add-Member -NotePropertyName PreProdExportRun -NotePropertyValue $(if ($PreProdRun) { $PreProdRun } else { '(unknown)' }) -Force
$summary | Add-Member -NotePropertyName DevExportRun -NotePropertyValue $(if ($DevRun) { $DevRun } else { '(unknown)' }) -Force
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

# The HTML drift report: tick the items to apply, download approved.json. It records the two export run ids so Apply can fetch the very same
# exports, so without numeric run ids (a manual run outside the pipeline) it is not built.
if ($PreProdRun -match '\A\d{1,12}\z' -and $DevRun -match '\A\d{1,12}\z')
{
    # The report is an extra: if it cannot be built, the comparison, the configurations and the MOF files above are still good.
    try
    {
        & $ReportTool `
            -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath -OutputPath $OutputPath `
            -TargetTenantDomain $dev.TenantDomain -CompleteWorkload $CompleteWorkloads -SourceRun $PreProdRun -TargetRun $DevRun
    }
    catch
    {
        $reason = (([string]$_.Exception.Message) -split "`r?`n")[0]
        Write-Host "##vso[task.logissue type=warning]drift-report.html was not built: $reason"
    }
}
else
{
    Write-Host 'The export run ids are not numeric, so drift-report.html was not built (it needs them to pin the exports).'
}
Write-Host "##vso[task.logissue type=warning]Drift: $($summary.OpenFindings) open ($($summary.ByKind)); $($summary.Manual) item(s) need manual action."
