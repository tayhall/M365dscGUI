# Microsoft Graph access for the user-id resolver (UserReferences.ps1). Reader certificate auth only; the thin wrappers around the Graph SDK
# exist so tests can mock them (the SDK is not loaded in tests and no live call is made there).

function Get-PEReaderApp
{
    # The Reader app registration written by tools\New-PETenantApps.ps1 (or Connect-PETenant): ApplicationId, TenantId, Thumbprint.
    # Throws when the file is missing or incomplete. Nothing else from the file (certificate details, permissions) is
    # passed on.
    [CmdletBinding()]
    param
    (
        [string]$Tenant = 'master'
    )

    $path = Get-PEAppInfoPath -Role Reader -Tenant $Tenant
    if (-not (Test-Path -LiteralPath $path -PathType Leaf))
    {
        throw "Reader app details not found at $path. Run tools\New-PETenantApps.ps1 first."
    }
    $info = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($name in 'ApplicationId', 'TenantId', 'Thumbprint')
    {
        if ([string]::IsNullOrWhiteSpace([string]$info.$name))
        {
            throw "Reader app details at $path have no $name."
        }
    }
    [pscustomobject]@{
        ApplicationId = [string]$info.ApplicationId
        TenantId      = [string]$info.TenantId
        Thumbprint    = [string]$info.Thumbprint
    }
}

function Connect-PEGraph
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $App
    )

    Import-Module Microsoft.Graph.Authentication -RequiredVersion (Get-PEPinnedVersion -Name MicrosoftGraphAuthentication) -ErrorAction Stop
    Connect-MgGraph -ClientId $App.ApplicationId -TenantId $App.TenantId -CertificateThumbprint $App.Thumbprint -NoWelcome -ErrorAction Stop
}

function Disconnect-PEGraph
{
    # Ends the process-wide Graph SDK session, including any session the caller had open before the scan.
    [CmdletBinding()]
    param ()

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

function Invoke-PEGraphPage
{
    # One GET; returns the response as a hashtable (value, @odata.nextLink). Throttling (429) is left to the SDK's
    # built-in retry handler in Invoke-MgGraphRequest; a request that still fails throws (the type becomes NotChecked).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Uri
    )

    Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable -ErrorAction Stop
}
