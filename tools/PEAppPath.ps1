# Where the Reader and Writer app registration of a tenant is kept, dot-sourced by the export tool, the apply tool and the
# PolicyEngine module so the rule lives in one place. The first tenant ('master') keeps the files where the registration
# tool always wrote them; every other tenant has its own folder:
#   ~\.m365dsc-policy\M365DSC-Policy-<Role>.json             tenant 'master'
#   ~\.m365dsc-policy\<slug>\M365DSC-Policy-<Role>.json      any other tenant
# The files hold the application id, tenant id and certificate thumbprint (the private key stays in the certificate store).

function Get-PEAppInfoPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Reader', 'Writer')]
        [string]$Role,

        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master'
    )

    $root = Join-Path $HOME '.m365dsc-policy'
    if ($Tenant -eq 'master')
    {
        return Join-Path $root "M365DSC-Policy-$Role.json"
    }
    return Join-Path (Join-Path $root $Tenant) "M365DSC-Policy-$Role.json"
}
