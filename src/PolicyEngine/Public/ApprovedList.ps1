function New-PEApprovedList
{
    <#
    .SYNOPSIS
    Builds an approved list: the items a reviewer accepted, by name, with the two exports they were reviewed against.

    .DESCRIPTION
    An item is @{ Action = Create|Update|Remove; ResourceType; Key; ExcludedProperties = @() }. Source is the PreProd export and
    Target the Dev export, each @{ Run = '<digits>'; ExportedAt = '<UTC ISO 8601>'; Fingerprint = '<64 hex>' }. The list never
    holds a property value. Counts are worked out from the items.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)] [string]$Tenant,
        [Parameter(Mandatory)] [string]$ApprovedBy,
        [Parameter(Mandatory)] [hashtable]$Source,
        [Parameter(Mandatory)] [hashtable]$Target,
        [Parameter(Mandatory)] [object[]]$Item,
        [string]$ModuleVersion = (Get-PEPinnedVersion -Name Microsoft365DSC),
        [datetime]$CreatedUtc = [datetime]::UtcNow
    )

    $items = foreach ($i in $Item)
    {
        foreach ($name in (Get-PEApprovedPropertyName $i))
        {
            if ($name -cnotin 'Action', 'ResourceType', 'Key', 'ExcludedProperties') { throw "Approved list (new): unknown property '$name' in an item." }
        }
        $excluded = Get-PEApprovedValue $i 'ExcludedProperties'
        [pscustomobject][ordered]@{
            Action             = [string](Get-PEApprovedValue $i 'Action')
            ResourceType       = [string](Get-PEApprovedValue $i 'ResourceType')
            Key                = [string](Get-PEApprovedValue $i 'Key')
            ExcludedProperties = @($excluded | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        }
    }
    $side = { param ($h) [pscustomobject][ordered]@{ Run = [string]$h.Run; ExportedAt = [string]$h.ExportedAt; Fingerprint = [string]$h.Fingerprint } }
    $list = [pscustomobject][ordered]@{
        Format        = 1
        CreatedUtc    = $CreatedUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        ApprovedBy    = $ApprovedBy
        Tenant        = $Tenant
        ModuleVersion = $ModuleVersion
        Source        = & $side $Source
        Target        = & $side $Target
        Items         = @($items)
        Counts        = @(Get-PEApprovedCount -Item $items)
    }
    Assert-PEApprovedList -List $list -Label '(new)'
    $list
}

function Save-PEApprovedList
{
    <# .SYNOPSIS Writes an approved list as UTF-8 (no BOM), LF, indented JSON; creates the folder; refuses to overwrite. #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)] [object]$List,
        [Parameter(Mandatory)] [string]$Path
    )

    Assert-PEApprovedList -List $List -Label $Path
    if (Test-Path -LiteralPath $Path)
    {
        throw "Approved list ${Path}: already exists; approvals are not overwritten. Save under a new name."
    }
    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $json = ($List | ConvertTo-Json -Depth 8) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Read-PEApprovedList
{
    <# .SYNOPSIS Reads and validates an approved list; throws a message starting "Approved list <path>:" if it is not acceptable. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Approved list ${Path}: file not found." }
    try { $list = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String -Depth 20 }
    catch { throw "Approved list ${Path}: not valid JSON ($($_.Exception.Message))." }
    Assert-PEApprovedList -List $list -Label $Path
    $list
}
