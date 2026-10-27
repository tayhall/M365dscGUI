<#
.SYNOPSIS
    Installs Microsoft365DSC and its pinned dependencies for the current user under PowerShell 7.
.DESCRIPTION
    Microsoft365DSC 2.x runs exports from PowerShell 7.6+. Update-M365DSCDependencies installs most dependencies from
    Windows PowerShell, where PowerShell 7 cannot see them, so this script reads the module's own dependency manifest
    and installs every pinned version into the PowerShell 7 CurrentUser scope. Safe to re-run: already installed
    versions are skipped.
.EXAMPLE
    pwsh -NoProfile -File tools\Install-M365DscDependencies.ps1
.EXAMPLE
    pwsh -NoProfile -File tools\Install-M365DscDependencies.ps1 -ModuleVersion 2.26.1021.1
#>
param
(
    [string]$ModuleVersion = '2.26.1021.1'
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.6')
{
    throw "Microsoft365DSC 2.x needs PowerShell 7.6 or later. Current: $($PSVersionTable.PSVersion). Upgrade with: winget install Microsoft.PowerShell"
}

if (-not (Get-InstalledPSResource -Name Microsoft365DSC -Version $ModuleVersion -ErrorAction SilentlyContinue))
{
    Install-PSResource -Name Microsoft365DSC -Version $ModuleVersion -Repository PSGallery -Scope CurrentUser -TrustRepository -AcceptLicense -SkipDependencyCheck
    "Installed Microsoft365DSC $ModuleVersion"
}

$moduleBase = (Get-Module -ListAvailable -Name Microsoft365DSC | Where-Object { $_.Version -eq [version]$ModuleVersion } | Select-Object -First 1).ModuleBase
$manifestPath = Join-Path $moduleBase 'Dependencies\Manifest.psd1'
if (-not (Test-Path $manifestPath))
{
    throw "Dependency manifest not found at $manifestPath"
}

foreach ($dependency in (Import-PowerShellDataFile $manifestPath).Dependencies)
{
    $present = Get-InstalledPSResource -Name $dependency.ModuleName -Version $dependency.RequiredVersion -ErrorAction SilentlyContinue
    if ($present)
    {
        "ok        $($dependency.ModuleName) $($dependency.RequiredVersion)"
        continue
    }
    Install-PSResource -Name $dependency.ModuleName -Version $dependency.RequiredVersion -Repository PSGallery -Scope CurrentUser -TrustRepository -AcceptLicense -SkipDependencyCheck
    "installed $($dependency.ModuleName) $($dependency.RequiredVersion)"
}

Import-Module Microsoft365DSC -RequiredVersion $ModuleVersion -WarningAction SilentlyContinue
Confirm-M365DSCDependencies
'Dependency check passed.'
