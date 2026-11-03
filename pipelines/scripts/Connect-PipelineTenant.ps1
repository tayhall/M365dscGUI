<#
.SYNOPSIS
    Makes a tenant's app registration available to the repo's tools on a pipeline agent: imports its certificate and writes the
    app details file that tools\Export-M365DscTenant.ps1 (and the apply tools) read.
.DESCRIPTION
    Values come from Key Vault through the pipeline (the certificate as a base64 PFX in an environment variable, never a parameter,
    so it is not echoed). The details file is written where tools\PEAppPath.ps1 expects it, so the existing tools run unchanged.
    Reader certificates go to CurrentUser\My; a Writer certificate goes to LocalMachine\My because the Local Configuration Manager
    runs as SYSTEM.
.EXAMPLE
    $env:PE_CERT_PFX_BASE64 = '...'; pwsh -File Connect-PipelineTenant.ps1 -Slug dev -Role Reader -ApplicationId <guid> -TenantId contoso-dev.onmicrosoft.com
#>
param
(
    [Parameter(Mandatory)]
    [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
    [string]$Slug,

    [Parameter(Mandatory)]
    [ValidateSet('Reader', 'Writer')]
    [string]$Role,

    [Parameter(Mandatory)]
    [string]$ApplicationId,

    [Parameter(Mandatory)]
    [string]$TenantId,

    # When given, the imported certificate must have this thumbprint (it is removed again if not).
    [string]$ExpectedThumbprint,

    # Optional certificate password (environment variable PE_CERT_PASSWORD).
    [string]$PfxPasswordVariable = 'PE_CERT_PASSWORD'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tools\PEAppPath.ps1')

$pfxBase64 = [Environment]::GetEnvironmentVariable('PE_CERT_PFX_BASE64')
if (-not $pfxBase64) { throw 'PE_CERT_PFX_BASE64 is not set: the pipeline must pass the Key Vault certificate secret in it.' }
$password = [Environment]::GetEnvironmentVariable($PfxPasswordVariable)
$securePassword = if ($password) { ConvertTo-SecureString $password -AsPlainText -Force } else { [securestring]::new() }

$bytes = [Convert]::FromBase64String($pfxBase64)
$store = if ($Role -eq 'Writer') { 'Cert:\LocalMachine\My' } else { 'Cert:\CurrentUser\My' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.pfx')
try
{
    [IO.File]::WriteAllBytes($temporary, $bytes)
    $cert = Import-PfxCertificate -FilePath $temporary -CertStoreLocation $store -Password $securePassword
}
finally
{
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

if ($ExpectedThumbprint -and $cert.Thumbprint -ine ($ExpectedThumbprint -replace '\s', ''))
{
    Remove-Item -LiteralPath "$store\$($cert.Thumbprint)" -Force
    throw "The certificate in Key Vault has thumbprint $($cert.Thumbprint), not the expected $ExpectedThumbprint. Nothing was kept."
}

$infoPath = Get-PEAppInfoPath -Role $Role -Tenant $Slug
New-Item -ItemType Directory -Force -Path (Split-Path $infoPath -Parent) | Out-Null
[ordered]@{ ApplicationId = $ApplicationId; TenantId = $TenantId; Thumbprint = $cert.Thumbprint } |
    ConvertTo-Json | Set-Content -LiteralPath $infoPath -Encoding utf8

# Expose the thumbprint to later steps (Azure Pipelines logging command; harmless elsewhere).
"##vso[task.setvariable variable=$($Slug)_$($Role)_Thumbprint]$($cert.Thumbprint)"
"$Role certificate $($cert.Thumbprint) imported to $store; app details written for tenant '$Slug'."
