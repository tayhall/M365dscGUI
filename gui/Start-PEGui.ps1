<#
.SYNOPSIS
    Starts the drift engine web GUI on http://localhost:<Port>.
.DESCRIPTION
    With -Mock, copies the fake data set in gui/mock-data to data/gui-mock (git-ignored, replaced on every start) and
    serves that, so requests and jobs the GUI writes never touch the committed mock data.
    Without -Mock, serves the view-model files in -DataRoot (default data/gui), which the engine's processing step
    writes (phase 2).
.EXAMPLE
    ./gui/Start-PEGui.ps1 -Mock
#>
param(
    [string]$DataRoot,
    [int]$Port = 8080,
    # Startup token every request must carry; a random one is made when omitted and printed in the address to open.
    [string]$Token,
    [switch]$Mock
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name Pode | Where-Object Version -GE ([version]'2.12.0'))) {
    throw 'Pode 2.12 or later is required: Install-PSResource -Name Pode -Scope CurrentUser'
}
Import-Module Pode -MinimumVersion 2.12.0

if ($Mock) {
    $DataRoot = Join-Path $repo 'data/gui-mock'
    if (Test-Path $DataRoot) { Remove-Item $DataRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $DataRoot) | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot 'mock-data') -Destination $DataRoot -Recurse
} elseif (-not $DataRoot) {
    $DataRoot = Join-Path $repo 'data/gui'
}
if (-not (Test-Path (Join-Path $DataRoot 'index.json'))) {
    throw "No index.json in '$DataRoot'. Use -Mock to run on the fake data set."
}
# Pode's threads do not share this session's current location, so hand them an absolute path.
$DataRoot = Convert-Path -LiteralPath $DataRoot

if (-not $Token) {
    $Token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
}
Write-Host "Drift engine GUI (data: $DataRoot$(if ($Mock) { ', mock' }))"
Write-Host "Open this address once; the browser then keeps the token in a cookie:"
Write-Host "    http://localhost:$Port/?token=$Token" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'server.ps1') -DataRoot $DataRoot -Port $Port -Token $Token -Mock:$Mock
