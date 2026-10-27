<#
.SYNOPSIS
    Prints the Microsoft365DSC commands an administrator of a new tenant runs to create the Reader and Writer apps.
.DESCRIPTION
    Thin wrapper over Get-PETenantSetupScript: DSC's own permission lists and Update-M365DSCAzureAdApplication, with the
    tenant name filled in, and the steps DSC's command does not do (admin consent, directory roles).
.EXAMPLE
    pwsh -NoProfile -File tools\Get-PETenantSetup.ps1 -Slug dev -TenantId contoso-dev.onmicrosoft.com
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)][ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')][string]$Slug,
    [Parameter(Mandatory)][string]$TenantId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue
(Get-PETenantSetupScript).Replace('{slug}', $Slug).Replace('{tenant}', $TenantId)
