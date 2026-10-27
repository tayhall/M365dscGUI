# One rule for where a tenant's app registration files are (tools\PEAppPath.ps1), shared with the export and apply tools.
$appPathScript = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\PEAppPath.ps1'
# The module test copies the module folder away from the repository; there the tools folder does not exist, and nothing that needs it runs.
if (Test-Path -LiteralPath $appPathScript) { . $appPathScript }

function Get-PETenantPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [string]$DataRoot
    )

    return Join-Path (Get-PEDataRoot -Override $DataRoot) 'tenants.json'
}

function Get-PETenantApp
{
    # The Reader or Writer app of a tenant (ApplicationId, TenantId, Thumbprint), read from its app file. Throws when the
    # file is missing or incomplete. Nothing else from the file is passed on.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Reader', 'Writer')]
        [string]$Role,

        [string]$Tenant = 'master'
    )

    $path = Get-PEAppInfoPath -Role $Role -Tenant $Tenant
    if (-not (Test-Path -LiteralPath $path -PathType Leaf))
    {
        throw "$Role app details for tenant '$Tenant' not found at $path. Connect the tenant first (tools\New-PETenantApps.ps1, or the Tenants page of the GUI)."
    }
    $info = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($name in 'ApplicationId', 'TenantId', 'Thumbprint')
    {
        if ([string]::IsNullOrWhiteSpace([string]$info.$name))
        {
            throw "$Role app details at $path have no $name."
        }
    }
    [pscustomobject]@{ ApplicationId = [string]$info.ApplicationId; TenantId = [string]$info.TenantId; Thumbprint = [string]$info.Thumbprint }
}
function Test-PETenantAppConnection
{
    # Signs in with an app (certificate auth) and reads the organisation, to prove a registration works; throws with the
    # reason when it does not. A thin wrapper so tests can replace it.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApplicationId,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$Thumbprint
    )

    Import-Module Microsoft.Graph.Authentication -WarningAction SilentlyContinue
    Connect-MgGraph -ClientId $ApplicationId -TenantId $TenantId -CertificateThumbprint $Thumbprint -NoWelcome -ErrorAction Stop
    $organization = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName'
    if (@($organization.value).Count -eq 0)
    {
        throw 'The app signed in but could not read the organisation; check its admin consent.'
    }
}

function Test-PEAppOwnership
{
    # Whether an application can be treated as ours before it is given consent and directory roles. A display name proves
    # nothing (anyone who can register an application can pre-create one), and neither does a certificate identifier (the
    # caller who adds a key chooses it, and the key itself cannot be read back). What proves it: this tool recorded the
    # object id on this machine when it created the application. On top of that, defence in depth: no client secret, exactly
    # one key (our certificate), no federated credential (a way to sign in as the app without any key or secret), and nobody
    # but the signing-in administrator as owner. Returns $null when it is ours, otherwise the reason it is not.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        $Application,

        [AllowNull()]
        [string]$RecordedObjectId,

        [AllowNull()]
        [object[]]$Owners = @(),

        [AllowNull()]
        [object[]]$FederatedCredentials = @(),

        [Parameter(Mandatory)]
        [string]$AdminObjectId
    )

    if ([string]::IsNullOrEmpty($RecordedObjectId) -or [string]$Application.id -cne $RecordedObjectId) { return 'this tool has no record of creating it' }
    if (@($Application.passwordCredentials | Where-Object { $null -ne $_ }).Count -gt 0) { return 'it has a client secret' }
    if (@($Application.keyCredentials | Where-Object { $null -ne $_ }).Count -ne 1) { return 'it does not have exactly one certificate' }
    if (@($FederatedCredentials | Where-Object { $null -ne $_ }).Count -gt 0) { return 'it has a federated credential' }
    $foreign = @($Owners | Where-Object { $null -ne $_ -and [string]$_.id -ne $AdminObjectId })
    if ($foreign.Count -gt 0) { return "it has $($foreign.Count) owner(s) other than the signed-in administrator" }
    return $null
}

function Test-PEServicePrincipalOwnership
{
    # The same defence in depth for the service principal of a reused application: no credentials of its own and no owner but
    # the signing-in administrator. Returns $null when it is fine, otherwise the reason.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        $ServicePrincipal,

        [AllowNull()]
        [object[]]$Owners = @(),

        [Parameter(Mandatory)]
        [string]$AdminObjectId
    )

    if (@($ServicePrincipal.passwordCredentials | Where-Object { $null -ne $_ }).Count -gt 0) { return 'its service principal has a client secret' }
    if (@($ServicePrincipal.keyCredentials | Where-Object { $null -ne $_ }).Count -gt 0) { return 'its service principal has a certificate' }
    $foreign = @($Owners | Where-Object { $null -ne $_ -and [string]$_.id -ne $AdminObjectId })
    if ($foreign.Count -gt 0) { return "its service principal has $($foreign.Count) owner(s) other than the signed-in administrator" }
    return $null
}

function Convert-PEPermissionToRead
{
    # DSC's "read" permission list for most areas names the ReadWrite permission (its Read and Update lists are both 81
    # permissions here, 56 of the "read" ones ReadWrite). For the Reader app, take the Read variant wherever Graph offers one
    # (Application.ReadWrite.All becomes Application.Read.All) and keep ReadWrite only where Graph has no Read permission.
    # Only Graph permissions are changed. Returns @{ Permissions; Narrowed; Remaining } (Remaining: the ReadWrite ones kept).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Permission,

        # The application permission names Graph offers (its service principal's app roles).
        [Parameter(Mandatory)]
        [string[]]$GraphRoleValue
    )

    $narrowed = 0
    $remaining = [System.Collections.Generic.List[string]]::new()
    $result = foreach ($p in $Permission)
    {
        $name = [string]$p.PermissionName
        if ($name -match 'ReadWrite')
        {
            $candidate = $name -replace 'ReadWrite', 'Read'
            if ([string]$p.Api -eq 'graph' -and $GraphRoleValue -contains $candidate)
            {
                $narrowed++
                @{ Api = $p.Api; PermissionName = $candidate }
                continue
            }
            $remaining.Add("$($p.Api):$name")
        }
        @{ Api = $p.Api; PermissionName = $name }
    }
    $unique = @($result | Group-Object { "$($_.Api):$($_.PermissionName)" } | ForEach-Object { $_.Group[0] })
    [pscustomobject]@{ Permissions = $unique; Narrowed = $narrowed; Remaining = @($remaining | Sort-Object -Unique) }
}

function Get-PETenantBlueprint
{
    # The blueprints a tenant follows, master blueprint first; the last one is the tenant's own. A tenant with no stored
    # list follows the master blueprint alone.
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$MasterBlueprint,

        [string]$DataRoot
    )

    $stored = @(Get-PETenant -Slug $Tenant -DataRoot $DataRoot).Blueprints | Where-Object { $_ }
    if (@($stored).Count -eq 0)
    {
        return @($MasterBlueprint)
    }
    return @($stored)
}
