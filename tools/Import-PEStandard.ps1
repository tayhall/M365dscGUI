<#
.SYNOPSIS
    Imports a published standard (the ASD Blueprint for Secure Cloud) as a read-only standard blueprint.
.DESCRIPTION
    Thin wrapper over Import-PEStandard in the PolicyEngine module. Without -Path it takes the latest release tag of the ASD Blueprint
    repo (or -Tag), clones that tag into data\sources\asd-<tag> if it is not there yet, and imports the DSC files from
    static\content\files\automation\dsc. The files are parsed with DSC's own parser, never run. Placeholder items and items with a property
    the pinned Microsoft365DSC does not have are not stored: the summary says how many and why (Get-PEStandardCoverage lists them).
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

    # A folder that already holds the DSC files; skips the download.
    [string]$Path,

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$repository = 'https://github.com/ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud.git'
$root = if ($DataRoot) { $DataRoot } else { Join-Path $PSScriptRoot '..\data' }

if (-not $Path)
{
    if (-not $Tag)
    {
        $tags = @(git ls-remote --tags --sort=-v:refname $repository 'refs/tags/v*' | ForEach-Object { ($_ -split "`t")[1] -replace '^refs/tags/', '' -replace '\^\{\}$', '' } | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })
        if ($tags.Count -eq 0)
        {
            throw "No release tag found at $repository."
        }
        $Tag = $tags[0]
    }
    $clone = Join-Path $root "sources\asd-$Tag"
    if (-not (Test-Path -LiteralPath $clone))
    {
        New-Item -ItemType Directory -Path (Split-Path -Parent $clone) -Force | Out-Null
        # Only the DSC folder is checked out: the website content below it nests deep enough to pass the Windows path limit.
        git clone --depth 1 --branch $Tag --filter=blob:none --sparse $repository $clone
        if ($LASTEXITCODE -ne 0)
        {
            throw "git clone of $Tag failed."
        }
        git -C $clone sparse-checkout set static/content/files/automation/dsc
        if ($LASTEXITCODE -ne 0)
        {
            throw "git sparse-checkout in $clone failed."
        }
    }
    $Path = Join-Path $clone 'static\content\files\automation\dsc'
}
elseif (-not $Tag)
{
    $Tag = Split-Path -Leaf $Path
}

$arguments = @{
    Name          = $Standard
    Path          = $Path
    SourceName    = 'ASD Blueprint for Secure Cloud'
    SourceUrl     = 'https://github.com/ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud'
    SourceVersion = $Tag
    Attribution   = 'ASD Blueprint for Secure Cloud, Australian Signals Directorate, CC BY 4.0'
    DataRoot      = $root
}
$result = Import-PEStandard @arguments -WarningAction SilentlyContinue

"Standard '$($result.Name)' version $($result.Version) from $($result.SourceVersion): $($result.Covered) of $($result.Total) settings stored ($($result.NotCovered) not covered)"
$result.ByReason.GetEnumerator() | Sort-Object Name | ForEach-Object { '  {0}: {1}' -f $_.Name, $_.Value }
if ($result.Version -gt 1)
{
    "  added $($result.Added), changed $($result.Changed), removed $($result.Removed) since the previous version"
}
