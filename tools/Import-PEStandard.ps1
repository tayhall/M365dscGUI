<#
.SYNOPSIS
    Imports a published standard (the ASD Blueprint for Secure Cloud) as a read-only standard blueprint.
.DESCRIPTION
    Thin wrapper over Import-PEStandardRelease in the PolicyEngine module. Without -Path it takes the latest release tag of the ASD
    Blueprint repo (or -Tag), fetches that tag into data\sources\asd-<tag> (a sparse clone of the DSC folder) if it is not there yet, and
    imports the DSC files. The files are parsed with DSC's own parser, never run. Placeholder items and items with a property the pinned
    Microsoft365DSC does not have are not stored: the summary says how many and why (Get-PEStandardCoverage lists them).
    Source: ASD Blueprint for Secure Cloud, Australian Signals Directorate, CC BY 4.0.
.EXAMPLE
    pwsh -NoProfile -File tools\Import-PEStandard.ps1 -Standard asd
.EXAMPLE
    pwsh -NoProfile -File tools\Import-PEStandard.ps1 -Standard asd -Tag v1.4.0
#>
param
(
    [Parameter(Mandatory)]
    [ValidateSet('asd')]
    [string]$Standard,

    # A release tag such as v1.4.0. Default: the latest vX.Y.Z tag.
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string]$Tag,

    # A folder that already holds the DSC files; skips the download. With it, -Tag names the version (default: the folder name).
    [string]$Path,

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$arguments = @{ Standard = $Standard; DataRoot = $(if ($DataRoot) { $DataRoot } else { Join-Path $PSScriptRoot '..\data' }) }
if ($Tag)
{
    $arguments.Tag = $Tag
}
if ($Path)
{
    $arguments.Path = $Path
    if (-not $Tag)
    {
        $arguments.Tag = Split-Path -Leaf $Path
    }
}
$result = Import-PEStandardRelease @arguments -WarningAction SilentlyContinue

"Standard '$($result.Name)' version $($result.Version) from $($result.SourceVersion): $($result.Covered) of $($result.Total) settings stored ($($result.NotCovered) not covered)"
$result.ByReason.GetEnumerator() | Sort-Object Name | ForEach-Object { '  {0}: {1}' -f $_.Name, $_.Value }
if ($result.Version -gt 1)
{
    "  added $($result.Added), changed $($result.Changed), removed $($result.Removed) since the previous version"
}
