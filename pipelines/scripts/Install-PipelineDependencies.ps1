<#
.SYNOPSIS
    Checks and installs Microsoft365DSC, its dependencies and the Graph authentication module into the Windows PowerShell 5.1
    all-users module path, for a pipeline agent.
.DESCRIPTION
    Microsoft365DSC 2.x runs its exports from PowerShell 7.6+, but the Local Configuration Manager (which applies MOF files)
    runs as SYSTEM and only sees C:\Program Files\WindowsPowerShell\Modules. PowerShell 7 also reads that folder, so one copy
    there serves both. Versions come from the repo's pin (src\PolicyEngine\Data\Versions.psd1) and from the module's own
    dependency manifest (Dependencies\Manifest.psd1); nothing is listed twice here. Safe to re-run: an installed version is
    skipped. Needs an elevated session (the agent's local admin) because the target is under Program Files.
.EXAMPLE
    pwsh -NoProfile -File pipelines\scripts\Install-PipelineDependencies.ps1
#>
param
(
    # Default: the AllUsers 5.1 path. Only change it for a test run.
    [string]$ModulePath = (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

"PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)); Windows PowerShell 5.1 present: $([bool](Get-Command "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ErrorAction SilentlyContinue))"
if ($PSVersionTable.PSVersion -lt [version]'7.6')
{
    throw "Microsoft365DSC 2.x needs PowerShell 7.6 or later. This agent has $($PSVersionTable.PSVersion). Use an image with pwsh 7.6+."
}
$principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))
{
    throw "Installing into $ModulePath needs an elevated session. Run the agent as an administrator."
}
New-Item -ItemType Directory -Force -Path $ModulePath | Out-Null

# Both PowerShell 5.1 and 7 must find the folder; the LCM needs it in the machine PSModulePath.
$machinePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
if (@($machinePath -split ';') -notcontains $ModulePath)
{
    [Environment]::SetEnvironmentVariable('PSModulePath', "$machinePath;$ModulePath".Trim(';'), 'Machine')
    "Added $ModulePath to the machine PSModulePath"
}
if (@($env:PSModulePath -split ';') -notcontains $ModulePath) { $env:PSModulePath = "$env:PSModulePath;$ModulePath" }

$pin = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src\PolicyEngine\Data\Versions.psd1')

function Test-ModuleInPath
{
    param ([string]$Name, [string]$Version)
    # A module folder under the target path with that version folder (Save-PSResource lays out <Name>\<Version>).
    Test-Path -LiteralPath (Join-Path $ModulePath "$Name\$Version")
}

function Install-ToPath
{
    param ([string]$Name, [string]$Version)
    if (Test-ModuleInPath -Name $Name -Version $Version)
    {
        "ok        $Name $Version"
        return
    }
    Save-PSResource -Name $Name -Version $Version -Repository PSGallery -Path $ModulePath -TrustRepository -SkipDependencyCheck -AcceptLicense
    if (-not (Test-ModuleInPath -Name $Name -Version $Version)) { throw "$Name $Version was not saved to $ModulePath" }
    "installed $Name $Version"
}

if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) -and -not (Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue))
{
    Register-PSResourceRepository -PSGallery -Trusted
}

Install-ToPath -Name 'Microsoft365DSC' -Version $pin.Microsoft365DSC
Install-ToPath -Name 'Microsoft.Graph.Authentication' -Version $pin.MicrosoftGraphAuthentication

$manifestPath = Join-Path $ModulePath "Microsoft365DSC\$($pin.Microsoft365DSC)\Dependencies\Manifest.psd1"
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Dependency manifest not found at $manifestPath" }
foreach ($dependency in (Import-PowerShellDataFile $manifestPath).Dependencies)
{
    Install-ToPath -Name $dependency.ModuleName -Version $dependency.RequiredVersion
}

# Prove it: load the pinned module from the target path and let DSC check its own dependencies.
Import-Module (Join-Path $ModulePath "Microsoft365DSC\$($pin.Microsoft365DSC)\Microsoft365DSC.psd1") -Force -WarningAction SilentlyContinue
Confirm-M365DSCDependencies
"Dependency check passed. Modules are under $ModulePath."
