<#
.SYNOPSIS
Runs the PolicyEngine Pester tests (Pester 5.7.1).

.DESCRIPTION
Usage:
    pwsh -NoProfile -File tools\Invoke-PETests.ps1           # every test (the default)
    pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Fast     # skip tests tagged 'Slow'
    pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\Rectify.Tests.ps1 -Fast

Tests tagged 'Slow' parse a complete generated DSC configuration: each parse loads the Microsoft365DSC DSC keywords
(about 3 seconds), so they dominate the run time. -Fast is for quick iteration; run without it before committing.
Exits with 1 when any test fails, 0 otherwise.

.PARAMETER Fast
Excludes tests tagged 'Slow'.

.PARAMETER Path
Test files or folders; defaults to the repository's tests folder.

.PARAMETER Output
Pester output verbosity (None, Normal, Detailed, Diagnostic). Defaults to Detailed.
#>
[CmdletBinding()]
param
(
    [switch]$Fast,

    [string[]]$Path,

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed'
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 5.7.1

if (-not $Path)
{
    $Path = @(Join-Path (Split-Path -Parent $PSScriptRoot) 'tests')
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = $Path
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = $Output
if ($Fast)
{
    $configuration.Filter.ExcludeTag = @('Slow')
}

$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed')
{
    exit 1
}
exit 0
