<#
.SYNOPSIS
    Registers a tenant whose Reader (and Writer) app was created with Microsoft365DSC's own commands.
.DESCRIPTION
    Thin wrapper over Connect-PETenant in the PolicyEngine module. Print the DSC commands to run in the new tenant first:
    pwsh -NoProfile -File tools\Get-PETenantSetup.ps1 -Slug dev -TenantId contoso-dev.onmicrosoft.com
.EXAMPLE
    pwsh -NoProfile -File tools\Connect-PETenant.ps1 -Slug dev -TenantId contoso-dev.onmicrosoft.com -ReaderApplicationId <guid> -ReaderThumbprint <thumbprint> -WriterApplicationId <guid> -WriterThumbprint <thumbprint>
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)][string]$Slug,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$DisplayName,
    [Parameter(Mandatory)][string]$ReaderApplicationId,
    [Parameter(Mandatory)][string]$ReaderThumbprint,
    [string]$WriterApplicationId,
    [string]$WriterThumbprint,
    [switch]$SkipVerify,
    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue
$arguments = @{} + $PSBoundParameters
Connect-PETenant @arguments | Format-List
