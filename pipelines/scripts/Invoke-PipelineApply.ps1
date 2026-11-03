<#
.SYNOPSIS
    Applies (or only tests) the MOF files of a compare run on Dev through the Local Configuration Manager. The whole apply step.
.DESCRIPTION
    Dev's identifiers come from pipelines\config\Dev.psd1. The Writer certificate is imported (it must be the one the MOFs were compiled
    with: its thumbprint is in the report's ConfigurationData.psd1) and always removed again. Changes are applied before Removals; with
    -Workloads the workload folders are applied in the order given. The LCM only runs from Windows PowerShell 5.1, so
    tools\Invoke-PELcm.ps1 is run with powershell.exe. Run it from an AzurePowerShell task.
    It stops, rather than apply nothing, when the layout of the compare run (Combined or PerWorkload, in the report's summary.json) does not
    match -Workloads, or when a named workload has no folder. In Apply mode a resource that is still not in the desired state fails the step.
#>
param
(
    # The DriftReport artifact folder of the compare run.
    [Parameter(Mandatory)]
    [string]$ReportPath,

    [ValidateSet('Test', 'Apply')]
    [string]$Mode = 'Test',

    # Empty: a Combined compare run. Otherwise the workload prefixes to apply, in order, for example AAD,Intune.
    [ValidatePattern('\A[A-Za-z0-9,]*\z')]
    [string]$Workloads = '',

    [ValidateSet('True', 'False')]
    [string]$IncludeRemovals = 'False',

    # Name of the compare run being applied, shown in the log with the export runs it used (from the report's summary.json).
    [ValidatePattern('\A[\w .#()-]{0,100}\z')]
    [string]$CompareRun = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$lcm = Join-Path $repoRoot 'tools\Invoke-PELcm.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# What is being applied.
$summary = Get-Content -LiteralPath (Join-Path $ReportPath 'summary.json') -Raw | ConvertFrom-Json
"Compare run: $(if ($CompareRun) { $CompareRun } else { '(unknown)' }); generated $($summary.GeneratedAtUtc); PreProd export run $($summary.PreProdExportRun); Dev export run $($summary.DevExportRun)"
"Drift: $($summary.OpenFindings) open ($($summary.ByKind)); layout $($summary.MofLayout); mode $Mode; removals $IncludeRemovals"

$names = @($Workloads -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($summary.MofLayout -eq 'PerWorkload' -and $names.Count -eq 0) { throw 'This compare run was PerWorkload: set the workloads parameter (for example AAD,Intune,EXO,Teams), or nothing would be applied.' }
if ($summary.MofLayout -ne 'PerWorkload' -and $names.Count -gt 0) { throw 'This compare run was Combined: leave the workloads parameter empty.' }
if ($names.Count -eq 0) { $roots = @(Join-Path $ReportPath 'MOF') }
else
{
    foreach ($name in $names) { if (-not (Test-Path -LiteralPath (Join-Path $ReportPath $name) -PathType Container)) { throw "No folder for workload '$name' in the compare run (it has: $(@(Get-ChildItem -LiteralPath $ReportPath -Directory | ForEach-Object Name) -join ', '))." } }
    $roots = @($names | ForEach-Object { Join-Path (Join-Path $ReportPath $_) 'MOF' })
}
$kinds = @('Changes')
if ($IncludeRemovals -eq 'True') { $kinds += 'Removals' }

$expected = [string](Import-PowerShellDataFile -Path (Join-Path $ReportPath 'ConfigurationData.psd1')).NonNodeData.CertificateThumbprint
if ($expected -notmatch '^[0-9A-Fa-f]{40}$') { throw 'No valid certificate thumbprint in the compare run''s ConfigurationData.psd1; refusing to apply.' }

$found = 0
try
{
    & (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1') -Environment Dev -Role Writer -ExpectedThumbprint $expected

    foreach ($kind in $kinds)
    {
        foreach ($root in $roots)
        {
            $mof = Get-ChildItem -LiteralPath (Join-Path $root $kind) -Filter *.mof -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $mof) { "No $kind MOF under ${root}: nothing to do there."; continue }
            $found++
            "== $kind ($($mof.FullName)) mode $Mode"
            $output = @(& $windowsPowerShell -NoProfile -File $lcm -MofPath $mof.FullName -Mode $Mode 2>&1)
            $exit = $LASTEXITCODE
            $json = $output | Where-Object { "$_" -match '^\s*\{' } | Select-Object -Last 1
            if ($exit -ne 0 -or -not $json) { throw "The LCM step for $kind ($root) did not return a result (exit code $exit). Output:`n$($output -join "`n")" }
            $result = $json | ConvertFrom-Json
            "In desired state: $(@($result.InDesiredState).Count); not in desired state: $(@($result.NotInDesiredState).Count)"
            $result.NotInDesiredState | ForEach-Object { "  $($_.ResourceId) $($_.Error)" }
            if ($result.Error) { throw "LCM error in $kind ($root): $($result.Error)" }
            # A test is expected to find differences; an apply that leaves some has failed, and Removals must not follow it.
            if ($Mode -eq 'Apply' -and @($result.NotInDesiredState).Count -gt 0) { throw "$kind ($root): $(@($result.NotInDesiredState).Count) resource(s) are still not in the desired state after the apply." }
        }
    }
    if ($found -eq 0) { 'Nothing to apply: the compare run has no MOF files for the chosen kinds (there is no drift, or no Changes).' }
}
finally
{
    & (Join-Path $PSScriptRoot 'Disconnect-PipelineTenant.ps1') -Slug dev -Role Writer
}
