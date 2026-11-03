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
$vault = $config.KeyVault
$vaultFile = "pipelines\config\$Environment.psd1"
$context = Get-AzContext
$who = if ($context) { "$($context.Account.Id) in subscription '$($context.Subscription.Name)'" } else { 'no Azure context' }
Write-Host "Reading secret '$secretName' from Key Vault '$vault' (https://$vault.vault.azure.net) as $who."
try
{
    $secret = Get-AzKeyVaultSecret -VaultName $vault -Name $secretName -ErrorAction Stop
}
catch
{
    $detail = $_.Exception.Message
    $inner = $_.Exception.InnerException
    while ($inner) { $detail += " | $($inner.Message)"; $inner = $inner.InnerException }
    $hint = switch -Regex ($detail)
    {
        'no data of the requested type|No such host|name or service not known|could not be resolved|nodename nor servname|NameResolutionFailure'
        {
            "The name '$vault.vault.azure.net' does not resolve. Either the Key Vault name '$vault' (KeyVault in $vaultFile) is wrong or the vault does not exist, or the vault is in another cloud, or it is behind a private endpoint the agent cannot resolve. Check the exact name in the Azure portal, and that the agent can reach it."
            break
        }
        'Forbidden|403|not authorized|does not have secrets get permission|AuthorizationFailed|Caller is not authorized'
        {
            "The vault '$vault' exists but the identity of the service connection ($who) may not read secrets from it. Give it 'Key Vault Secrets User' (RBAC) or Get on secrets (access policy). If the vault has a firewall, the agent's address must be allowed."
            break
        }
        'SecretNotFound|404|not found'
        {
            "The vault '$vault' was reached but has no secret named '$secretName' (name is ShortName '$($config.ShortName)' + '-Cert-$Role'). Check the secret name and that it is enabled and not deleted."
            break
        }
        'AADSTS|Unauthorized|401|token'
        {
            "Sign-in to the vault failed. Check the service connection belongs to the tenant that owns '$vault' and that the AzurePowerShell step uses the right one (Dev vs PreProd)."
            break
        }
        default { 'Could not read the secret. See the message below.' }
    }
    throw "Key Vault read failed for secret '$secretName' in vault '$vault'. $hint`nAzure said: $detail"
}
if (-not $secret) { throw "Key Vault '$vault' was reached but returned nothing for secret '$secretName' (it may be disabled, expired or deleted)." }
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

# The app details file is written BEFORE the import: Disconnect-PipelineTenant.ps1 finds the certificate through it, so a failure part
# way through still gets cleaned up. The thumbprint is the one worked out above, not whatever the import returns (a PFX with a chain
# returns several certificates).
$infoPath = Get-PEAppInfoPath -Role $Role -Tenant $slug
New-Item -ItemType Directory -Force -Path (Split-Path $infoPath -Parent) | Out-Null
[ordered]@{ ApplicationId = ([guid]$config[$appIdKey]).ToString(); TenantId = $config.TenantDomain; Thumbprint = $thumbprint } |
    ConvertTo-Json | Set-Content -LiteralPath $infoPath -Encoding utf8

$temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.pfx')
try
{
    [IO.File]::WriteAllBytes($temporary, $bytes)
    $null = Import-PfxCertificate -FilePath $temporary -CertStoreLocation $store -Password ([securestring]::new())
}
finally
{
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
if (-not (Test-Path -LiteralPath "$store\$thumbprint")) { throw "The certificate $thumbprint is not in $store after the import." }

"$Role certificate $thumbprint ($secretName) imported to $store; app details written for tenant '$slug'."
