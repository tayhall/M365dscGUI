<#
.SYNOPSIS
    Reads a tenant app's certificate from Key Vault, imports it, and writes the app details file that tools\Export-M365DscTenant.ps1
    (and the apply tools) read. With -ThumbprintOnly it only reports the certificate's thumbprint.
.DESCRIPTION
    The Key Vault secret <ShortName>-Cert-<Role> holds the certificate as a base64 PFX (no password),
    read with Get-AzKeyVaultSecret (the step must be an AzurePowerShell task, which is already signed in), and the thumbprint is taken
    from the certificate itself, so no thumbprint is stored anywhere. The application id comes from the settings file.
    Reader certificates go to CurrentUser\My; a Writer certificate goes to LocalMachine\My because the Local Configuration Manager runs
    as SYSTEM. The key is not exportable. Disconnect-PipelineTenant.ps1 removes it again.
.EXAMPLE
    Connect-PipelineTenant.ps1 -Slug dev -Role Reader -VaultName dev-kv -ShortName dev -ApplicationId <guid> -TenantId contoso-dev.onmicrosoft.com
.EXAMPLE
    Connect-PipelineTenant.ps1 -Role Writer -VaultName dev-kv -ShortName dev -ThumbprintOnly
#>
param
(
    [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
    [string]$Slug,

    [Parameter(Mandatory)]
    [ValidateSet('Reader', 'Writer')]
    [string]$Role,

    [Parameter(Mandatory)]
    [ValidatePattern('\A[A-Za-z0-9-]{3,24}\z')]
    [string]$VaultName,

    # The environment's short name: the secret is <ShortName>-Cert-<Role>.
    [Parameter(Mandatory)]
    [ValidatePattern('\A[A-Za-z0-9-]{1,24}\z')]
    [string]$ShortName,

    [string]$ApplicationId,

    [string]$TenantId,

    # When given, the certificate must have this thumbprint (nothing is kept if not).
    [string]$ExpectedThumbprint,

    # Report the thumbprint (and set the pipeline variable named by -VariableName) without importing anything.
    [switch]$ThumbprintOnly,

    [string]$VariableName
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if (-not $ThumbprintOnly)
{
    if (-not $Slug) { throw '-Slug is needed to import the certificate.' }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact(([string]$ApplicationId).Trim(), 'D', [ref]$parsed)) { throw '-ApplicationId must be a GUID.' }
    if (-not $TenantId) { throw '-TenantId is needed to import the certificate.' }
    . (Join-Path $repoRoot 'tools\PEAppPath.ps1')
}

$secretName = "$ShortName-Cert-$Role"
$secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $secretName
if (-not $secret) { throw "Key Vault secret $secretName was not found in $VaultName." }
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

if ($ThumbprintOnly)
{
    if ($VariableName) { "##vso[task.setvariable variable=$VariableName]$thumbprint" }
    "$secretName thumbprint: $thumbprint"
    return
}

$store = if ($Role -eq 'Writer') { 'Cert:\LocalMachine\My' } else { 'Cert:\CurrentUser\My' }
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

$infoPath = Get-PEAppInfoPath -Role $Role -Tenant $Slug
New-Item -ItemType Directory -Force -Path (Split-Path $infoPath -Parent) | Out-Null
[ordered]@{ ApplicationId = $parsed.ToString(); TenantId = $TenantId; Thumbprint = $cert.Thumbprint } |
    ConvertTo-Json | Set-Content -LiteralPath $infoPath -Encoding utf8

"$Role certificate $($cert.Thumbprint) ($secretName) imported to $store; app details written for tenant '$Slug'."
