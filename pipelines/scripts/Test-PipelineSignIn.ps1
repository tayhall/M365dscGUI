<#
.SYNOPSIS
    Shows, on screen, who the pipeline signs in as and whether that sign-in works, before the export or apply starts. Never stops the run.
.DESCRIPTION
    Reads the app details file written by Connect-PipelineTenant.ps1 (application id, tenant, thumbprint), prints them with the certificate
    found in the store (subject, expiry, private key, which store, which account the agent runs as), then signs in to Microsoft Graph with
    Connect-MgGraph -ClientId -TenantId -CertificateThumbprint, the same app-only sign-in the export uses. A failure prints the full
    error with its AADSTS code and what that code usually means. Nothing here is a secret; no token or key is printed.
    Run it in its own process (Invoke-PipelineExport.ps1 does) so the Graph module it loads cannot affect the export.
.EXAMPLE
    Test-PipelineSignIn.ps1 -Environment Dev -Role Reader
#>
param
(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'PreProd')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateSet('Reader', 'Writer')]
    [string]$Role
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tools\PEAppPath.ps1')
$slug = $Environment.ToLowerInvariant()
$infoPath = Get-PEAppInfoPath -Role $Role -Tenant $slug
Write-Host "=== Sign-in check: $Environment $Role ==="
if (-not (Test-Path -LiteralPath $infoPath)) { Write-Host "No app details file at $infoPath (the certificate step did not run or failed)."; return }
$app = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
Write-Host "Agent runs as : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "Tenant        : $($app.TenantId)"
Write-Host "Application id: $($app.ApplicationId)"
Write-Host "Thumbprint    : $($app.Thumbprint)"

$cert = $null
foreach ($store in 'Cert:\LocalMachine\My', 'Cert:\CurrentUser\My')
{
    $found = Get-Item -LiteralPath (Join-Path $store $app.Thumbprint) -ErrorAction SilentlyContinue
    if ($found) { $cert = $found; Write-Host "Certificate   : found in $store"; break }
}
if (-not $cert) { Write-Host 'Certificate   : NOT FOUND in LocalMachine\My or CurrentUser\My, so the sign-in cannot work.'; return }
Write-Host "  subject     : $($cert.Subject)"
Write-Host "  valid       : $($cert.NotBefore.ToString('u')) to $($cert.NotAfter.ToString('u'))$(if ($cert.NotAfter -lt (Get-Date)) { '  <-- EXPIRED' })"
Write-Host "  private key : $($cert.HasPrivateKey)"

if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue))
{
    try { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop } catch { Write-Host "Microsoft.Graph.Authentication is not available, so the sign-in test is skipped: $($_.Exception.Message)"; return }
}
try
{
    $null = Connect-MgGraph -ClientId $app.ApplicationId -TenantId $app.TenantId -CertificateThumbprint $app.Thumbprint -NoWelcome -ErrorAction Stop
    $context = Get-MgContext
    Write-Host "Sign-in       : OK (app-only, auth type $($context.AuthType), app '$($context.AppName)')."
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
catch
{
    $detail = [string]$_.Exception.Message
    $inner = $_.Exception.InnerException
    while ($inner) { $detail += " | $($inner.Message)"; $inner = $inner.InnerException }
    $hint = switch -Regex ($detail)
    {
        'AADSTS700027' { 'The certificate is not registered on this app. Upload the certificate (the public part) to the app registration: Certificates & secrets.'; break }
        'AADSTS700016' { 'No application with this id exists in this tenant. Check the application id and that the tenant is the one the app was created in.'; break }
        'AADSTS90002|AADSTS900023' { 'The tenant was not found. Check the tenant id or domain.'; break }
        'AADSTS7000215|AADSTS7000222' { 'The app was sent a secret or a key that does not match (or expired).'; break }
        'AADSTS50076|AADSTS50079|interaction_required|user interaction|multi-factor|MFA' { 'Entra asked for a user (MFA or interaction), meaning this was not an app-only certificate sign-in, or a conditional access policy blocks the workload identity. Confirm the application id is of an app registration with the certificate uploaded.'; break }
        'AADSTS500011|AADSTS650052' { 'The app lacks consent or the resource is not present in the tenant. Grant admin consent for the app permissions.'; break }
        default { 'See the message below.' }
    }
    Write-Host "Sign-in       : FAILED. $hint"
    Write-Host "Entra said    : $detail"
    Write-Host '##vso[task.logissue type=warning]The app sign-in check failed; see the "Sign-in check" lines above for the cause.'
}
