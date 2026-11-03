<#
.SYNOPSIS
    Reads a tenant app's certificate from Key Vault, imports it, and writes the app details file that tools\Export-M365DscTenant.ps1
    (and the apply tools) read. With -ThumbprintOnly it only reports the certificate's thumbprint.
.DESCRIPTION
    The environment's identifiers (Key Vault, short name, application id, tenant domain) come from pipelines\config\<Environment>.psd1
    through Get-PipelineConfig.ps1, which validates them. The Key Vault secret <ShortName>-Cert-<Role> holds the certificate as a base64
    PFX (no password), read with Get-AzKeyVaultSecret (the step must be an AzurePowerShell task, which is already signed in). The
    thumbprint is taken from the certificate itself, so no thumbprint is stored anywhere.
    Both certificates go to LocalMachine\My: the Writer because the Local Configuration Manager runs as SYSTEM, the Reader so the export
    finds it whichever account the agent uses. The key is not exportable. Needs an elevated session. Disconnect-PipelineTenant.ps1
    removes it again.
.EXAMPLE
    Connect-PipelineTenant.ps1 -Environment Dev -Role Reader
.EXAMPLE
    $thumbprint = Connect-PipelineTenant.ps1 -Environment Dev -Role Writer -ThumbprintOnly
#>
param
(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'PreProd')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateSet('Reader', 'Writer')]
    [string]$Role,

    # When given, the certificate must have this thumbprint (nothing is kept if not).
    [string]$ExpectedThumbprint,

    # Return the certificate's thumbprint without importing anything.
    [switch]$ThumbprintOnly,

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$appIdKey = "${Role}AppId"
$require = @('KeyVault', 'ShortName', $appIdKey)
if (-not $ThumbprintOnly) { $require += 'TenantDomain' }
$config = & (Join-Path $PSScriptRoot 'Get-PipelineConfig.ps1') -Environment $Environment -Require $require -ConfigPath $ConfigPath
$slug = $Environment.ToLowerInvariant()
if (-not $ThumbprintOnly) { . (Join-Path $repoRoot 'tools\PEAppPath.ps1') }

$secretName = "$($config.ShortName)-Cert-$Role"
$secret = Get-AzKeyVaultSecret -VaultName $config.KeyVault -Name $secretName
if (-not $secret) { throw "Key Vault secret $secretName was not found in $($config.KeyVault)." }
$pfxBase64 = ConvertFrom-SecureString -SecureString $secret.SecretValue -AsPlainText
$bytes = [Convert]::FromBase64String(($pfxBase64 -replace '\s', ''))

# The thumbprint of the certificate itself (loaded in memory only, nothing persisted).
$memoryCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes, '', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
$thumbprint = $memoryCert.Thumbprint
$memoryCert.Dispose()
if ($thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw "Unexpected thumbprint from $secretName." }
if ($ExpectedThumbprint -and $thumbprint -ine ($ExpectedThumbprint -replace '\s', ''))
{
    throw "The certificate in $secretName has thumbprint $thumbprint, not the expected $ExpectedThumbprint. Nothing was kept."
}

if ($ThumbprintOnly) { return $thumbprint }

$store = 'Cert:\LocalMachine\My'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.pfx')
try
{
    [IO.File]::WriteAllBytes($temporary, $bytes)
    $cert = Import-PfxCertificate -FilePath $temporary -CertStoreLocation $store -Password ([securestring]::new())
}
finally
{
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

$infoPath = Get-PEAppInfoPath -Role $Role -Tenant $slug
New-Item -ItemType Directory -Force -Path (Split-Path $infoPath -Parent) | Out-Null
[ordered]@{ ApplicationId = ([guid]$config[$appIdKey]).ToString(); TenantId = $config.TenantDomain; Thumbprint = $cert.Thumbprint } |
    ConvertTo-Json | Set-Content -LiteralPath $infoPath -Encoding utf8

"$Role certificate $($cert.Thumbprint) ($secretName) imported to $store; app details written for tenant '$slug'."
