function Get-PETenantSetupScript
{
    <#
    .SYNOPSIS
    The PowerShell an administrator of a new tenant runs to create the Reader and Writer apps with Microsoft365DSC's own
    commands, and the steps that follow. Nothing here is our own logic: the permission lists come from DSC
    (Get-M365DSCCompiledPermissionList) and the apps, permissions and certificates from Update-M365DSCAzureAdApplication.

    .DESCRIPTION
    Returns text. {slug} and {tenant} stand for the tenant's short name and its domain; the GUI fills them in. Run the
    script on a machine with Microsoft365DSC installed, as an administrator of the new tenant. Then register the result
    with Connect-PETenant (or the Tenants page of the GUI).

    What DSC's command does not do, and the script says so: it signs in with a username and password only (no MFA), grants
    admin consent only with those credentials, does not create the service principal and does not assign directory roles.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [string]$Pattern = (Get-PEWorkloadPattern)
    )

    $version = Get-PEPinnedVersion -Name Microsoft365DSC
    @"
# Run as an administrator of the tenant {tenant}, on a machine that has Microsoft365DSC $version installed.
Import-Module Microsoft365DSC -RequiredVersion $version
`$credential = Get-Credential   # an admin of {tenant}; DSC's command signs in with a username and password (no MFA)
`$resources = @((Get-M365DSCAllResources) | Where-Object { `$_ -match '$Pattern' })

foreach (`$role in @(@{ Name = 'Reader'; Access = 'Read' }, @{ Name = 'Writer'; Access = 'Update' }))
{
    `$permissions = @((Get-M365DSCCompiledPermissionList -ResourceNameList `$resources -PermissionType Application -AccessType `$role.Access).Permissions |
            ForEach-Object { @{ Api = `$_.API; PermissionName = `$_.PermissionName } })
    Update-M365DSCAzureAdApplication -ApplicationName "M365DSC-Policy-{slug}-`$(`$role.Name)" -Permissions `$permissions ``
        -Type Certificate -CreateSelfSignedCertificate -CertificatePath "`$HOME\M365DSC-Policy-{slug}-`$(`$role.Name).cer" ``
        -AdminConsent -Credential `$credential -TenantId '{tenant}'
}

# Then, because DSC's command stops short of these:
#  1. In the Entra admin center, open each of the two apps and grant admin consent for the requested permissions.
#  2. Give the Reader app the Global Reader role and the Writer app the roles it needs (Exchange Online and Teams
#     app-only access need a directory role on top of the Graph permissions).
#  3. Note each app's Application (client) ID and the thumbprint of its certificate:
Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -like 'CN=M365DSC-Policy-{slug}-*' | Select-Object Subject, Thumbprint
#  4. Register them here:  Connect-PETenant -Slug {slug} -TenantId {tenant} -ReaderApplicationId ... -ReaderThumbprint ... -WriterApplicationId ... -WriterThumbprint ...
"@
}

function Connect-PETenant
{
    <#
    .SYNOPSIS
    Registers a tenant: its Reader app (and Writer app) as created with Microsoft365DSC's own commands (see
    Get-PETenantSetupScript), so checks and reverts can run against it.

    .DESCRIPTION
    Writes the application ids, tenant id and certificate thumbprints to ~\.m365dsc-policy\<slug>\M365DSC-Policy-<Role>.json
    (the private keys stay in the certificate store), adds the tenant to the registry as a Replica and, unless
    -SkipVerify, signs in with the Reader app to prove the registration works. A Writer app is optional: without it the
    tenant can be checked but not brought into line. The slug 'master' is the tenant the blueprint is taken from.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Slug,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z')]
        [string]$TenantId,

        [string]$DisplayName,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z')]
        [string]$ReaderApplicationId,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[0-9A-Fa-f]{40}\z')]
        [string]$ReaderThumbprint,

        [ValidatePattern('\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z')]
        [string]$WriterApplicationId,

        [ValidatePattern('\A[0-9A-Fa-f]{40}\z')]
        [string]$WriterThumbprint,

        [switch]$SkipVerify,

        [string]$DataRoot
    )

    if ([bool]$WriterApplicationId -ne [bool]$WriterThumbprint)
    {
        throw 'Give both -WriterApplicationId and -WriterThumbprint, or neither.'
    }
    $apps = [ordered]@{ Reader = @($ReaderApplicationId, $ReaderThumbprint) }
    if ($WriterApplicationId) { $apps['Writer'] = @($WriterApplicationId, $WriterThumbprint) }

    $missing = @($apps.Values | ForEach-Object { $_[1] } | Where-Object { -not (Test-Path -LiteralPath "Cert:\CurrentUser\My\$_") })
    if ($missing.Count -gt 0)
    {
        throw "No certificate with thumbprint $($missing -join ', ') in Cert:\CurrentUser\My. The certificate DSC created must be on this machine (export it from the other one with its private key and import it)."
    }
    if (-not $SkipVerify)
    {
        Test-PETenantAppConnection -ApplicationId $ReaderApplicationId -TenantId $TenantId -Thumbprint $ReaderThumbprint
    }

    foreach ($role in $apps.Keys)
    {
        $path = Get-PEAppInfoPath -Role $role -Tenant $Slug
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        Write-PEJson -Path $path -InputObject ([ordered]@{
                Role          = $role
                Name          = "M365DSC-Policy-$Slug-$role"
                TenantId      = $TenantId
                ApplicationId = $apps[$role][0]
                Thumbprint    = $apps[$role][1].ToUpperInvariant()
            })
    }
    Set-PETenant -Slug $Slug -DisplayName $(if ($DisplayName) { $DisplayName } else { $TenantId }) -TenantId $TenantId -DataRoot $DataRoot
}
