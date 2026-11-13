<#
.SYNOPSIS
    What changed in ONE tenant between two of its own exports: a report, a revert configuration and a promote configuration.
.DESCRIPTION
    A thin arrangement of tools\Invoke-PEPipelineCompare.ps1 (and tools\New-PEDriftReport.ps1), called with two exports of the same tenant.
    -PreviousExportPath is what the tenant should look like (expected), -LatestExportPath is what it looks like now.
    Everything is written under <OutputPath>\<Tenant>\ (for example out\Dev\):
      Revert\            previous expected, latest target: Changes/Removals that put the tenant back to the previous export (the
                         layout of a compare run, so tools such as the Apply step can read it). With -ApplicationId,
                         -CertificateThumbprint and -OrganizationName (the tenant's Writer app) it is compiled to MOF.
      Promote\Changes.ps1, Promote\Removals.ps1
                         latest expected, previous target: the configuration that takes a tenant in the previous state to the
                         latest. Never compiled here: a MOF holds the identity of the tenant it will be applied to.
      Report.html        the drift report of the previous-to-latest comparison.
      Revert\MOF\Changes\localhost.mof, Revert\MOF\Removals\localhost.mof   the compiled revert (only with a Writer app).
      summary.json       tenant, the two export names and run ids, and the counts of both directions.
    Nothing here connects to a tenant and nothing is applied.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PETenantChanges.ps1 -Tenant Dev -PreviousExportPath prev -LatestExportPath latest -TargetTenantDomain contoso-dev.onmicrosoft.com -OutputPath out -PreviousRun 101 -LatestRun 102 -PreviousName v8 -LatestName v9
#>
param
(
    [Parameter(Mandatory)]
    [ValidatePattern('\A[A-Za-z0-9-]{1,24}\z')]
    [string]$Tenant,

    # Folders holding export.ps1 (as written by tools\Export-M365DscTenant.ps1).
    [Parameter(Mandatory)]
    [string]$PreviousExportPath,

    [Parameter(Mandatory)]
    [string]$LatestExportPath,

    [Parameter(Mandatory)]
    [string]$TargetTenantDomain,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,12}\z')]
    [string]$PreviousRun,

    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,12}\z')]
    [string]$LatestRun,

    # How the two exports are called, for example v8 and v9 (shown in the log, the report and summary.json).
    [Parameter(Mandatory)]
    [ValidatePattern('\A[\w .()-]{1,40}\z')]
    [string]$PreviousName,

    [Parameter(Mandatory)]
    [ValidatePattern('\A[\w .()-]{1,40}\z')]
    [string]$LatestName,

    [string[]]$CompleteWorkload = @('AAD', 'Intune', 'EXO', 'Teams'),

    # Noise rules file (noise\noise-rules.json): what a rule matches is not a change. The rules' tenant name is the tenant's own (dev, preprod),
    # as both sides of the comparison are that tenant.
    [string]$NoiseRulePath,

    # The tenant's Writer app: when all three are given the revert configuration is compiled to MOF.
    [string]$ApplicationId,
    [string]$CertificateThumbprint,
    [string]$OrganizationName
)

$ErrorActionPreference = 'Stop'
$CompleteWorkload = @($CompleteWorkload | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

"$Tenant changes: $PreviousName -> $LatestName"

foreach ($path in $PreviousExportPath, $LatestExportPath)
{
    if (-not (Test-Path -LiteralPath (Join-Path $path 'export.ps1'))) { throw "No export.ps1 in $path" }
}

# Both exports must have been made with the pinned Microsoft365DSC, otherwise the comparison would be between two different schemas.
foreach ($side in @(@{ Name = $PreviousName; Path = $PreviousExportPath; Label = 'previous' }, @{ Name = $LatestName; Path = $LatestExportPath; Label = 'latest' }))
{
    $file = [pscustomobject]@{ Name = "export of $($side.Name)"; Text = (Get-Content -LiteralPath (Join-Path $side.Path 'export.ps1') -Raw) }
    try { & (Get-Module PolicyEngine) { param ($f) Assert-PEUploadVersion -File @($f) } $file }
    catch
    {
        throw "The $($side.Label) export ($($side.Name)) was made with another Microsoft365DSC version than this installation is pinned to: $($_.Exception.Message) Take a fresh export first, then compare again."
    }
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = Join-Path (Resolve-Path -LiteralPath $OutputPath).ProviderPath $Tenant
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$compare = Join-Path $PSScriptRoot 'Invoke-PEPipelineCompare.ps1'
$compile = [bool]($ApplicationId -and $CertificateThumbprint -and $OrganizationName)
$slug = $Tenant.ToLowerInvariant()
$noise = if ($NoiseRulePath) { @{ NoiseRulePath = $NoiseRulePath; SourceTenant = $slug; TargetTenant = $slug } } else { @{} }

# Revert: the previous export is what the tenant should be, the latest is what it is.
$revertPath = Join-Path $OutputPath 'Revert'
$revertArguments = @{
    SourceExportPath = $PreviousExportPath; TargetExportPath = $LatestExportPath; TargetTenantDomain = $TargetTenantDomain
    OutputPath = $revertPath; CompleteWorkload = $CompleteWorkload
}
$revertArguments += $noise
if ($compile) { $revertArguments += @{ Compile = $true; ApplicationId = $ApplicationId; CertificateThumbprint = $CertificateThumbprint; OrganizationName = $OrganizationName } }
& $compare @revertArguments | Out-Null
$revert = Get-Content -LiteralPath (Join-Path $revertPath 'summary.json') -Raw | ConvertFrom-Json

# Promote: the latest export is what a tenant should be, the previous is what it was. Never compiled here.
$promotePath = Join-Path $OutputPath 'work-promote'
& $compare -SourceExportPath $LatestExportPath -TargetExportPath $PreviousExportPath -TargetTenantDomain $TargetTenantDomain `
    -OutputPath $promotePath -CompleteWorkload $CompleteWorkload @noise | Out-Null
$promote = Get-Content -LiteralPath (Join-Path $promotePath 'summary.json') -Raw | ConvertFrom-Json

# What changed is not the same as what could not be compared. A component an export could not read (a 403, an incomplete log) and an item left
# out of scope are findings of the comparison, but they say how the exports went, not that the tenant changed: the same on both sides, they would
# be reported as changes in every run. Only the rest counts as a change here; the others are counted apart as 'not compared'.
function Get-ChangeCount
{
    param ([string]$DriftPath, $Summary)
    $notChanges = 'NotChecked', 'Excluded'
    if (-not (Test-Path -LiteralPath $DriftPath)) { return [pscustomobject]@{ Changes = [int]$Summary.OpenFindings; ByKind = [string]$Summary.ByKind; NotCompared = 0 } }
    $open = @(Get-Content -LiteralPath $DriftPath -Raw | ConvertFrom-Json | Where-Object { $_.State -eq 'Open' })
    $changes = @($open | Where-Object { $_.Kind -notin $notChanges })
    $byKind = (@($changes | Group-Object Kind | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ', '
    [pscustomobject]@{ Changes = $changes.Count; ByKind = $byKind; NotCompared = $open.Count - $changes.Count }
}
$revertCount = Get-ChangeCount (Join-Path $revertPath 'drift.json') $revert
$promoteCount = Get-ChangeCount (Join-Path $promotePath 'drift.json') $promote
foreach ($kind in 'Changes', 'Removals')
{
    $from = Join-Path $promotePath "$kind.ps1"
    if (Test-Path -LiteralPath $from)
    {
        New-Item -ItemType Directory -Force -Path (Join-Path $OutputPath 'Promote') | Out-Null
        Copy-Item -LiteralPath $from -Destination (Join-Path $OutputPath "Promote\$kind.ps1")
    }
}
Remove-Item -LiteralPath $promotePath -Recurse -Force

# The report of the previous-to-latest comparison. An extra: if it cannot be built, everything above is still good. Its tenant slug is
# '<tenant>-changes', so an approved list made from it is refused by the approved apply (which expects 'dev').
$reportWork = Join-Path $OutputPath 'work-report'
$reportNoise = if ($NoiseRulePath) { @{ NoiseRulePath = $NoiseRulePath; SourceTenant = $slug; RuleTenant = $slug } } else { @{} }
try
{
    & (Join-Path $PSScriptRoot 'New-PEDriftReport.ps1') -SourceExportPath $PreviousExportPath -TargetExportPath $LatestExportPath `
        -TargetTenantDomain $TargetTenantDomain -OutputPath $reportWork -SourceRun $PreviousRun -TargetRun $LatestRun `
        -Tenant ($Tenant.ToLowerInvariant() + '-changes') -SourceLabel "$Tenant $PreviousName" -TargetLabel "$Tenant $LatestName" `
        -CompleteWorkload $CompleteWorkload @reportNoise | Out-Null
    Copy-Item -LiteralPath (Join-Path $reportWork 'drift-report.html') -Destination (Join-Path $OutputPath 'Report.html')
}
catch
{
    $reason = (([string]$_.Exception.Message) -split "`r?`n")[0]
    Write-Host "##vso[task.logissue type=warning]Report.html was not built: $reason"
}
finally
{
    if (Test-Path -LiteralPath $reportWork) { Remove-Item -LiteralPath $reportWork -Recurse -Force }
}

# What was compared, in the revert summary (the Apply step reads it) and in the top-level summary.
$generated = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm')
$identity = [ordered]@{
    Tenant = $Tenant; PreviousName = $PreviousName; LatestName = $LatestName; PreviousRun = $PreviousRun; LatestRun = $LatestRun
    GeneratedAtUtc = $generated
}
foreach ($key in $identity.Keys) { $revert | Add-Member -NotePropertyName $key -NotePropertyValue $identity[$key] -Force }
$revert | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $revertPath 'summary.json') -Encoding utf8

$summary = [ordered]@{}
foreach ($key in $identity.Keys) { $summary[$key] = $identity[$key] }
$summary['Compiled'] = $compile
$summary['Revert'] = [ordered]@{ OpenFindings = $revertCount.Changes; ByKind = $revertCount.ByKind; Manual = $revert.Manual; NotCompared = $revertCount.NotCompared }
$summary['Promote'] = [ordered]@{ OpenFindings = $promoteCount.Changes; ByKind = $promoteCount.ByKind; Manual = $promote.Manual; NotCompared = $promoteCount.NotCompared }
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputPath 'summary.json') -Encoding utf8

if ($revertCount.Changes -eq 0 -and $promoteCount.Changes -eq 0) { "No changes: $Tenant is the same in $PreviousName and $LatestName." }
else { "Changes: $($revertCount.Changes) open ($($revertCount.ByKind)); $($revert.Manual) item(s) need manual action." }
if ($revertCount.NotCompared -gt 0) { "$($revertCount.NotCompared) item(s) not compared (not readable in an export, or out of scope); see the report." }
