function Get-PECheck
{
    <#
    .SYNOPSIS
    Reads a saved check (checks\<CheckId>\result.json) and returns its document: CheckId, Kind (Full or Scan),
    BlueprintName, BlueprintVersion, Findings and State (Records, NotChecked, Meta).

    .DESCRIPTION
    -CheckId reads one check. -Latest reads the newest check (CheckIds are sortable timestamps); with -Kind it takes the
    newest check of that Kind, so a Scan is never returned as the last Full check. -Kind with -CheckId asserts the kind.
    Throws when the check does not exist.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param
    (
        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidatePattern('^\d{8}-\d{6}$')]
        [string]$CheckId,

        [Parameter(Mandatory, ParameterSetName = 'Latest')]
        [switch]$Latest,

        [ValidateSet('Full', 'Scan')]
        [string]$Kind,

        # With -Latest: the newest check of this tenant. A check written before tenants existed belongs to 'master'.
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $checksRoot = Join-Path $root 'checks'

    if ($PSCmdlet.ParameterSetName -eq 'ById')
    {
        $document = Read-PEJson -Path (Join-Path $checksRoot "$CheckId\result.json")
        if ($null -eq $document)
        {
            throw "Check '$CheckId' not found under $checksRoot (no result.json)."
        }
        if ($Kind -and $document.Kind -ne $Kind)
        {
            throw "Check '$CheckId' is a $($document.Kind) check, not $Kind."
        }
        return $document
    }

    $folders = @(Get-ChildItem -LiteralPath $checksRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending)
    foreach ($folder in $folders)
    {
        $document = Read-PEJson -Path (Join-Path $folder.FullName 'result.json')
        $documentTenant = if ($null -ne $document -and $document.PSObject.Properties['TenantSlug'] -and $document.TenantSlug) { [string]$document.TenantSlug } else { 'master' }
        if ($null -ne $document -and (-not $Kind -or $document.Kind -eq $Kind) -and $documentTenant -ceq $Tenant)
        {
            return $document
        }
    }
    throw "No $(if ($Kind) { "$Kind " })check found under $checksRoot (tenant '$Tenant')."
}
