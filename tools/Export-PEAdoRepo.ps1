<#
.SYNOPSIS
Copies the files the Azure DevOps repo needs (pipelines\ado-manifest.psd1) into a folder.

.DESCRIPTION
Reads the manifest, checks that every listed path exists, and copies it into -Destination (a clone of the ADO repo, or any folder).
Nothing is deleted unless -RemoveStale is given. Never overwritten when they already exist in the destination, because they hold that
repo's own values: pipelines\config\*.psd1, pipelines\pipeline.settings.psd1 and the generated pipelines\*.yaml.
Files in the copied folders (pipelines, src, tools, tests, docs) that the manifest does not list are reported as stale;
-RemoveStale deletes them, but never pipelines\config, settings or generated YAML, and never a .git folder.
-RunTests runs tools\Invoke-PETests.ps1 inside the destination afterwards and exits 1 when a test fails.

.EXAMPLE
pwsh -NoProfile -File tools\Export-PEAdoRepo.ps1 -Destination C:\src\ado\M365dscGUI -RunTests

.PARAMETER Destination
Target folder. Created when missing. Must not be inside this repo.

.PARAMETER RemoveStale
Delete stale files from the destination.

.PARAMETER RunTests
Run the tests in the destination after copying.

.PARAMETER ManifestPath
Defaults to pipelines\ado-manifest.psd1.
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter(Mandatory)]
    [string]$Destination,

    [switch]$RemoveStale,

    [switch]$RunTests,

    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $root 'pipelines\ado-manifest.psd1' }

$dest = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
$rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
if ($dest -eq $rootFull -or $dest.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Destination $dest is inside this repo ($rootFull). Use a separate folder." }

$manifest = Import-PowerShellDataFile -Path $ManifestPath
$paths = @($manifest.Include) + @($manifest.ModuleFiles) + @($manifest.Tests) + @('tests\fixtures')

# What the manifest means, as a list of files (relative to the root).
$missing = New-Object System.Collections.Generic.List[string]
$files = New-Object System.Collections.Generic.List[string]
foreach ($p in $paths)
{
    $full = Join-Path $root $p
    if (-not (Test-Path -LiteralPath $full)) { $missing.Add($p); continue }
    if (Test-Path -LiteralPath $full -PathType Container)
    {
        foreach ($f in Get-ChildItem -LiteralPath $full -Recurse -File) { $files.Add($f.FullName.Substring($rootFull.Length + 1)) }
    }
    else { $files.Add($p) }
}
if ($missing.Count) { throw "The manifest lists paths that do not exist: $($missing -join ', '). Nothing was copied." }

# Files that belong to the destination repo, not to us.
function Test-Protected([string]$Relative)
{
    $Relative -like 'pipelines\config\*' -or $Relative -eq 'pipelines\pipeline.settings.psd1' -or $Relative -like 'pipelines\*.yaml'
}

$excluded = @($manifest.ExcludeData | ForEach-Object { $_.ToLowerInvariant() })
$wanted = @($files | Sort-Object -Unique | Where-Object { $excluded -notcontains $_.ToLowerInvariant() })

$copied = 0; $kept = 0
foreach ($rel in $wanted)
{
    $target = Join-Path $dest $rel
    if ((Test-Protected $rel) -and (Test-Path -LiteralPath $target)) { $kept++; continue }
    if ($PSCmdlet.ShouldProcess($target, 'Copy'))
    {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $rel) -Destination $target -Force
        $copied++
    }
}

# Stale: files in the copied top folders that the manifest does not list.
$lookup = @{}; foreach ($rel in $wanted) { $lookup[$rel.ToLowerInvariant()] = $true }
$stale = @()
foreach ($top in 'pipelines', 'src', 'tools', 'tests', 'docs')
{
    $folder = Join-Path $dest $top
    if (-not (Test-Path -LiteralPath $folder)) { continue }
    foreach ($f in Get-ChildItem -LiteralPath $folder -Recurse -File)
    {
        $rel = $f.FullName.Substring($dest.Length + 1)
        if ($rel -match '(^|\\)\.git(\\|$)' -or (Test-Protected $rel)) { continue }
        if (-not $lookup.ContainsKey($rel.ToLowerInvariant())) { $stale += $rel }
    }
}
if ($stale.Count)
{
    if ($RemoveStale) { foreach ($rel in $stale) { if ($PSCmdlet.ShouldProcess((Join-Path $dest $rel), 'Remove stale file')) { Remove-Item -LiteralPath (Join-Path $dest $rel) -Force } } }
    else { Write-Warning ("$($stale.Count) file(s) in the destination are not in the manifest (run with -RemoveStale to delete them):`n  " + ($stale -join "`n  ")) }
}

Write-Host "Copied $copied file(s) to $dest; left $kept destination-owned file(s) alone; $($stale.Count) stale."

if ($RunTests)
{
    & pwsh -NoProfile -File (Join-Path $dest 'tools\Invoke-PETests.ps1') -Output Normal
    if ($LASTEXITCODE -ne 0) { Write-Error "Tests failed in $dest."; exit 1 }
}
