<#
.SYNOPSIS
    Creates the Reader (and Writer) app registrations of a tenant, signing in as an administrator with a device code, and
    registers the tenant. Replaces New-M365DscAppRegistration.ps1 and Set-M365DscAppRoles.ps1.
.DESCRIPTION
    What comes from Microsoft365DSC: the resource list and the permission lists (Get-M365DSCCompiledPermissionList, exactly
    as DSC gives them). What is ours, because DSC's
    Update-M365DSCAzureAdApplication cannot do it (it needs a username and password, grants consent only with those, does not
    create the service principal and assigns no directory roles): sign in with a device code (MFA works), then with that
    administrator's own token create the app, its certificate, the service principal, the admin consent and the directory
    roles, and finally Connect-PETenant (which proves the Reader can sign in and registers the tenant).

    The sign-in prompt is written to the output (Microsoft's device-login address and a code, valid for 15 minutes); the GUI worker shows it.
    Needs Microsoft365DSC at the pinned version and an administrator who can consent (Global Administrator, or Privileged
    Role Administrator plus Application Administrator). Nothing is written to the repository; the certificates stay in the
    CurrentUser store and the app files go to ~\.m365dsc-policy.
.EXAMPLE
    pwsh -NoProfile -File tools\New-PETenantApps.ps1 -Slug dev -TenantId contoso-dev.onmicrosoft.com
#>
[CmdletBinding()]
param
(
    [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
    [string]$Slug = 'master',

    [Parameter(Mandatory)]
    [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z')]
    [string]$TenantId,

    [string]$DisplayName,

    # Which DSC resources the apps must be able to work with (a regular expression on the resource name).
    [string]$Pattern = ('^(' + ((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Workloads.psd1')).Workloads.Prefix -join '|') + ')'),

    # Reader only: no Writer app, so the tenant can be checked but not brought into line.
    [switch]$NoWriter,

    # Directory roles. Exchange Online and Teams app-only access need one on top of the Graph permissions.
    [string[]]$ReaderRoles = @('Global Reader'),

    [string[]]$WriterRoles = @(),

    [ValidateRange(1, 36)]
    [int]$MonthsValid = 12,

    # How long to wait for the new apps to replicate before the Reader's first sign-in is judged failed.
    [ValidateRange(1, 30)]
    [int]$VerifyMinutes = 5,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
# A child process started with -File gets one comma-joined string for a list parameter; split it (role names have spaces, never commas).
$ReaderRoles = @($ReaderRoles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$WriterRoles = @($WriterRoles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
. (Join-Path $PSScriptRoot 'PEAppPath.ps1')
. (Join-Path $PSScriptRoot 'PEDeviceLogin.ps1')
$pin = (Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Versions.psd1')).Microsoft365DSC
Import-Module Microsoft365DSC -RequiredVersion $pin -WarningAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue
Import-Module Microsoft.Graph.Authentication -WarningAction SilentlyContinue

# 1. Sign in as an administrator. The device code is printed by the Graph SDK (and picked up by the GUI worker).
"Sign in as an administrator of $TenantId to continue."
# The Graph SDK's own device sign-in proved unreliable (it asks for a second code and times out after two minutes), so the device flow is ours (PEDeviceLogin.ps1) and the SDK is given the token.
$token = Get-PEDeviceLoginToken -TenantId $TenantId -Scope 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'RoleManagement.ReadWrite.Directory', 'Directory.Read.All'
Connect-MgGraph -AccessToken (ConvertTo-SecureString $token -AsPlainText -Force) -NoWelcome -ErrorAction Stop
"Signed in."

# 3. What the apps need, from DSC (computed after the sign-in so the code appears at once; the sign-in itself times out after two minutes).
$resources = @((Get-M365DSCAllResources) | Where-Object { $_ -match $Pattern })
function Get-DscPermission
{
    param ([string]$Access)
    @((Get-M365DSCCompiledPermissionList -ResourceNameList $resources -PermissionType Application -AccessType $Access).Permissions |
            ForEach-Object { @{ Api = $_.API; PermissionName = $_.PermissionName } })
}
$plan = [ordered]@{ Reader = @{ Access = 'Read'; Roles = $ReaderRoles } }
if (-not $NoWriter) { $plan['Writer'] = @{ Access = 'Update'; Roles = $WriterRoles } }
foreach ($role in @($plan.Keys)) { $plan[$role].Permissions = @(Get-DscPermission -Access $plan[$role].Access) }
# DSC's read list names the ReadWrite permission for most areas (56 of its 81 here). The Reader takes the Read variant wherever
# Graph offers one and keeps ReadWrite only where Graph has no Read permission; the Writer keeps DSC's update list as it is.
$graphSp = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=appRoles").value) | Select-Object -First 1
$graphValues = @($graphSp.appRoles | Where-Object { $_.allowedMemberTypes -contains 'Application' } | ForEach-Object { [string]$_.value })
$narrowing = & (Get-Module PolicyEngine) { param ($p, $g) Convert-PEPermissionToRead -Permission $p -GraphRoleValue $g } $plan.Reader.Permissions $graphValues
$plan.Reader.Permissions = @($narrowing.Permissions)
$readerWrite = @($narrowing.Remaining)
"Reader: $($narrowing.Narrowed) permission(s) narrowed from ReadWrite to Read; $($readerWrite.Count) have no Read variant and stay ReadWrite$(if ($readerWrite.Count) { ': ' + ($readerWrite -join ', ') })"
# DSC names the API of each permission ('graph', 'exchange', ...). Its own lookup is internal to the module, so this is a
# small map of ours; any other name is looked up in the tenant by id or display name.
$apiAppIds = @{
    'graph'                                = '00000003-0000-0000-c000-000000000000'
    'Microsoft Graph'                      = '00000003-0000-0000-c000-000000000000'
    'exchange'                             = '00000002-0000-0ff1-ce00-000000000000'
    'Office 365 Exchange Online'           = '00000002-0000-0ff1-ce00-000000000000'
    'sharepoint'                           = '00000003-0000-0ff1-ce00-000000000000'
    'Office 365 SharePoint Online'         = '00000003-0000-0ff1-ce00-000000000000'
    'Verifiable Credentials Service Admin' = '6a8b4b39-c021-437c-b060-5a14a3fd65f3'
}
$apiCache = @{}
function Get-ApiServicePrincipal
{
    param ([string]$Api)
    if (-not $apiCache.ContainsKey($Api))
    {
        $appId = if ($apiAppIds.ContainsKey($Api)) { $apiAppIds[$Api] } elseif ($Api -match '^[0-9a-fA-F-]{36}$') { $Api } else { $null }
        $filter = if ($appId) { "appId eq '$appId'" } else { "displayName eq '$($Api -replace "'", "''")'" }
        $apiCache[$Api] = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id,appId,appRoles").value) | Select-Object -First 1
    }
    $apiCache[$Api]
}
function Resolve-Permission
{
    # The app role id and the resource's service principal for one DSC permission; null when the API or role is not in this tenant.
    param ($Permission)
    $sp = Get-ApiServicePrincipal -Api $Permission.Api
    if ($null -eq $sp) { return $null }
    $appRole = @($sp.appRoles | Where-Object { $_.value -eq $Permission.PermissionName -and $_.allowedMemberTypes -contains 'Application' }) | Select-Object -First 1
    if ($null -eq $appRole) { return $null }
    [pscustomobject]@{ ResourceAppId = [string]$sp.appId; ResourceObjectId = [string]$sp.id; RoleId = [string]$appRole.id }
}

$adminId = [string](Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id').id
# What this tool created, recorded on this machine the moment each application exists. Only these are ever reused.
$createdPath = Join-Path (Split-Path (Get-PEAppInfoPath -Role Reader -Tenant $Slug)) "created-apps-$Slug.json"
function Get-CreatedApp
{
    param ([string]$Role)
    if (-not (Test-Path -LiteralPath $createdPath)) { return $null }
    $all = Get-Content -LiteralPath $createdPath -Raw | ConvertFrom-Json
    if ($all.PSObject.Properties[$Role]) { $all.$Role } else { $null }
}
function Save-CreatedApp
{
    param ([string]$Role, [string]$ObjectId, [string]$AppId)
    $all = [ordered]@{}
    if (Test-Path -LiteralPath $createdPath) { foreach ($p in (Get-Content -LiteralPath $createdPath -Raw | ConvertFrom-Json).PSObject.Properties) { $all[$p.Name] = $p.Value } }
    $all[$Role] = [ordered]@{ ObjectId = $ObjectId; AppId = $AppId; CreatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    New-Item -ItemType Directory -Force -Path (Split-Path $createdPath) | Out-Null
    $all | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $createdPath -Encoding utf8
}
$certDir = Join-Path $HOME '.m365dsc-policy\certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null
$created = [ordered]@{}
$unresolved = [System.Collections.Generic.List[string]]::new()

foreach ($role in $plan.Keys)
{
    $name = if ($Slug -eq 'master') { "M365DSC-Policy-$role" } else { "M365DSC-Policy-$Slug-$role" }
    "[$role] $name"

    # Permissions: DSC's list, resolved to app role ids.
    $resolved = foreach ($permission in $plan[$role].Permissions)
    {
        $r = Resolve-Permission -Permission $permission
        if ($null -eq $r) { $unresolved.Add("$($permission.Api):$($permission.PermissionName)") } else { $r }
    }
    $resolved = @($resolved | Sort-Object ResourceAppId, RoleId -Unique)
    $requiredResourceAccess = @($resolved | Group-Object ResourceAppId | ForEach-Object {
            @{ resourceAppId = $_.Name; resourceAccess = @($_.Group | ForEach-Object { @{ id = $_.RoleId; type = 'Role' } }) }
        })

    # Certificate (private key stays in the CurrentUser store).
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=$name" -and $_.NotAfter -gt (Get-Date).AddDays(30) } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($null -eq $cert)
    {
        $cert = New-SelfSignedCertificate -CertStoreLocation 'Cert:\CurrentUser\My' -Subject "CN=$name" -KeySpec Signature -NotAfter (Get-Date).AddMonths($MonthsValid) -KeyLength 2048 -KeyAlgorithm RSA -HashAlgorithm SHA256
        "  created certificate $($cert.Thumbprint)"
    }
    # An apply runs through the Local Configuration Manager (SYSTEM), which reads certificates from the LocalMachine store, so the
    # Writer's certificate is also placed there (this needs an elevated session, as the apply does).
    if ($role -eq 'Writer' -and -not (Test-Path -LiteralPath "Cert:\LocalMachine\My\$($cert.Thumbprint)"))
    {
        if ([System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))
        {
            $transit = [guid]::NewGuid().ToString('N')
            $pfx = Join-Path ([System.IO.Path]::GetTempPath()) "$transit.pfx"
            try
            {
                $secret = ConvertTo-SecureString $transit -AsPlainText -Force
                $null = Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secret
                $null = Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\My' -Password $secret
                "  copied the Writer certificate to Cert:\LocalMachine\My"
            }
            finally { Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue }
        }
        else
        {
            Write-Warning "The Writer certificate $($cert.Thumbprint) is not in Cert:\LocalMachine\My. Applying through the Local Configuration Manager needs it there: import it from an elevated session."
        }
    }    $null = Export-Certificate -Cert $cert -Type CERT -FilePath (Join-Path $certDir "$name.cer") -Force
    $keyCredential = @{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = [Convert]::ToBase64String($cert.GetRawCertData()); displayName = $cert.Subject }

    # Application. Only the application this tool recorded creating is ever reused (Test-PEAppOwnership). One that merely has
    # the same name is refused: anyone who can register an application could have created it, and it would then be given
    # consent and directory roles.
    $reused = $false
    $recorded = Get-CreatedApp -Role $role
    $found = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$name'&`$select=id").value)
    $existing = $null
    if ($null -ne $recorded)
    {
        try { $existing = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($recorded.ObjectId)?`$select=id,appId,keyCredentials,passwordCredentials" }
        catch { $existing = $null }   # deleted since: a new one is created below
        if ($null -eq $existing -and @($found | Where-Object { $_.id -ne $recorded.ObjectId }).Count -gt 0) { throw "The application this tool created for $name was deleted, and another application now has that name. Delete or rename the other one, then run again." }
    }
    elseif ($found.Count -gt 0)
    {
        throw "An application named '$name' already exists and this tool has no record of creating it. It was not touched and nothing was granted to it. Delete or rename it in the Entra admin center, then run again."
    }
    if ($null -ne $existing)
    {
        $owners = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($existing.id)/owners?`$select=id").value)
        $federated = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($existing.id)/federatedIdentityCredentials").value)
        $problem = & (Get-Module PolicyEngine) { param ($a, $r, $o, $f, $m) Test-PEAppOwnership -Application $a -RecordedObjectId $r -Owners $o -FederatedCredentials $f -AdminObjectId $m } $existing $recorded.ObjectId $owners $federated $adminId
        if ($problem) { throw "The application '$name' cannot be reused ($problem). It was not touched and nothing was granted to it." }
        $app = $existing
        $reused = $true
        Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($existing.id)" -Body (@{ requiredResourceAccess = $requiredResourceAccess } | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
        "  updated application $($app.appId) (its certificate is kept)"
    }
    else
    {
        $body = @{ displayName = $name; signInAudience = 'AzureADMyOrg'; requiredResourceAccess = $requiredResourceAccess; keyCredentials = @($keyCredential) }
        $app = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json'
        Save-CreatedApp -Role $role -ObjectId ([string]$app.id) -AppId ([string]$app.appId)
        "  created application $($app.appId)"
    }

    # Service principal (the new application can take a moment to be visible). One that already exists for a reused
    # application must have no credentials or foreign owners before anything is granted to it.
    $clientSp = $null
    for ($i = 0; $i -lt 8 -and $null -eq $clientSp; $i++)
    {
        $clientSp = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id,keyCredentials,passwordCredentials").value) | Select-Object -First 1
        if ($null -eq $clientSp)
        {
            try { $clientSp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body (@{ appId = $app.appId } | ConvertTo-Json) -ContentType 'application/json' }
            catch { Start-Sleep -Seconds 8 }
        }
        elseif ($reused)
        {
            $spOwners = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($clientSp.id)/owners?`$select=id").value)
            $spProblem = & (Get-Module PolicyEngine) { param ($s, $o, $m) Test-PEServicePrincipalOwnership -ServicePrincipal $s -Owners $o -AdminObjectId $m } $clientSp $spOwners $adminId
            if ($spProblem) { throw "The service principal of '$name' cannot be reused ($spProblem). Nothing was granted to it." }
        }
    }
    if ($null -eq $clientSp) { throw "Could not create or find the service principal of $name." }
    # Admin consent: assign every requested application permission.
    $granted = 0
    foreach ($r in $resolved)
    {
        $assignment = @{ principalId = $clientSp.id; resourceId = $r.ResourceObjectId; appRoleId = $r.RoleId }
        for ($i = 0; $i -lt 4; $i++)
        {
            try { Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($clientSp.id)/appRoleAssignedTo" -Body ($assignment | ConvertTo-Json) -ContentType 'application/json' | Out-Null; $granted++; break }
            catch { if ($_.Exception.Message -match 'already exists') { break } elseif ($i -eq 3) { "  could not grant $($r.RoleId): $($_.Exception.Message)" } else { Start-Sleep -Seconds 5 } }
        }
    }
    "  admin consent: $granted granted of $($resolved.Count)"

    # Directory roles.
    foreach ($roleName in @($plan[$role].Roles | Where-Object { $_ }))
    {
        $definition = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=displayName eq '$($roleName -replace "'", "''")'").value) | Select-Object -First 1
        if ($null -eq $definition) { "  role '$roleName' not found"; continue }
        try
        {
            Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' -ContentType 'application/json' `
                -Body (@{ principalId = $clientSp.id; roleDefinitionId = $definition.id; directoryScopeId = '/' } | ConvertTo-Json) | Out-Null
            "  role '$roleName' assigned"
        }
        catch { if ($_.Exception.Message -match 'already exists') { "  role '$roleName' already assigned" } else { "  role '$roleName' not assigned: $($_.Exception.Message)" } }
    }
    $created[$role] = @{ ApplicationId = [string]$app.appId; Thumbprint = $cert.Thumbprint }
}
if ($unresolved.Count -gt 0) { "Not available in this tenant, skipped: $(($unresolved | Sort-Object -Unique) -join ', ')" }

# 4. Register the tenant. Connect-PETenant proves the Reader signs in; a new app needs a little time to replicate.
$arguments = @{ Slug = $Slug; TenantId = $TenantId; DisplayName = $(if ($DisplayName) { $DisplayName } else { $TenantId }); ReaderApplicationId = $created.Reader.ApplicationId; ReaderThumbprint = $created.Reader.Thumbprint }
if ($created.Contains('Writer')) { $arguments.WriterApplicationId = $created.Writer.ApplicationId; $arguments.WriterThumbprint = $created.Writer.Thumbprint }
$deadline = (Get-Date).AddMinutes($VerifyMinutes)
$registered = $false
while (-not $registered)
{
    try { Connect-PETenant @arguments | Out-Null; $registered = $true }
    catch
    {
        if ((Get-Date) -gt $deadline) { throw "The apps were created but the Reader could not sign in yet: $($_.Exception.Message). Run tools\Connect-PETenant.ps1 with the ids below once they have replicated." }
        "Waiting for the new apps to replicate ($($_.Exception.Message.Split("`n")[0]))"
        Start-Sleep -Seconds 15
    }
}
"Tenant '$Slug' registered."
$result = [ordered]@{ Slug = $Slug; TenantId = $TenantId; Reader = $created.Reader; Writer = $(if ($created.Contains('Writer')) { $created.Writer } else { $null }); Unresolved = @($unresolved | Sort-Object -Unique); ReaderReadWrite = $readerWrite }
if ($Json) { ($result | ConvertTo-Json -Depth 5 -Compress) } else { $result | ConvertTo-Json -Depth 5 }
