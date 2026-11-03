<#
.SYNOPSIS
    Undoes Connect-PipelineTenant.ps1: removes the tenant app's certificate from the agent's store and deletes the app details file.
.DESCRIPTION
    Run as the last step of a job (condition: always()), so a failed run does not leave a tenant certificate on a shared agent.
    Reads the thumbprint from the app details file that Connect-PipelineTenant.ps1 wrote. Nothing is an error if it is already gone.
#>
param
(
    [Parameter(Mandatory)]
    [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
    [string]$Slug,

    [Parameter(Mandatory)]
    [ValidateSet('Reader', 'Writer')]
    [string]$Role
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tools\PEAppPath.ps1')

$infoPath = Get-PEAppInfoPath -Role $Role -Tenant $Slug
if (Test-Path -LiteralPath $infoPath)
{
    $thumbprint = [string](Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json).Thumbprint
    $store = if ($Role -eq 'Writer') { 'Cert:\LocalMachine\My' } else { 'Cert:\CurrentUser\My' }
    if ($thumbprint -match '^[0-9A-Fa-f]{40}$' -and (Test-Path -LiteralPath "$store\$thumbprint"))
    {
        Remove-Item -LiteralPath "$store\$thumbprint" -Force
        "Removed $Role certificate $thumbprint from $store."
    }
    Remove-Item -LiteralPath $infoPath -Force
    "Removed $infoPath."
}
else
{
    "No app details for tenant '$Slug' ($Role): nothing to clean up."
}
