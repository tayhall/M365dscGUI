<#
.SYNOPSIS
    Applies (or only tests) the MOF files of a compare run on Dev through the Local Configuration Manager. The whole apply step.
.DESCRIPTION
    Dev's identifiers come from pipelines\config\Dev.psd1. The Writer certificate is imported (it must be the one the MOFs were compiled
    with: its thumbprint is in the report's ConfigurationData.psd1) and always removed again. Changes are applied before Removals; with
    -Workloads the workload folders are applied in the order given. The LCM only runs from Windows PowerShell 5.1, so
    tools\Invoke-PELcm.ps1 is run with powershell.exe. Run it from an AzurePowerShell task.
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
    [string]$IncludeRemovals = 'False'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$lcm = Join-Path $repoRoot 'tools\Invoke-PELcm.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$roots = @(@($Workloads -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | ForEach-Object { Join-Path (Join-Path $ReportPath $_) 'MOF' })
if ($roots.Count -eq 0) { $roots = @(Join-Path $ReportPath 'MOF') }
$kinds = @('Changes')
if ($IncludeRemovals -eq 'True') { $kinds += 'Removals' }

$expected = (Import-PowerShellDataFile -Path (Join-Path $ReportPath 'ConfigurationData.psd1')).NonNodeData.CertificateThumbprint
try
{
    & (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1') -Environment Dev -Role Writer -ExpectedThumbprint $expected

    foreach ($kind in $kinds)
    {
        foreach ($root in $roots)
        {
            $mof = Get-ChildItem -LiteralPath (Join-Path $root $kind) -Filter *.mof -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $mof) { "No $kind MOF under ${root}: skipped."; continue }
            "== $kind ($($mof.FullName)) mode $Mode"
            $result = (& $windowsPowerShell -NoProfile -File $lcm -MofPath $mof.FullName -Mode $Mode) | ConvertFrom-Json
            "In desired state: $(@($result.InDesiredState).Count); not in desired state: $(@($result.NotInDesiredState).Count)"
            $result.NotInDesiredState | ForEach-Object { "  $($_.ResourceId) $($_.Error)" }
            if ($result.Error) { throw "LCM error in $kind ($root): $($result.Error)" }
        }
    }
}
finally
{
    & (Join-Path $PSScriptRoot 'Disconnect-PipelineTenant.ps1') -Slug dev -Role Writer
}
