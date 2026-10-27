function Add-PEBlueprintType
{
    <#
    .SYNOPSIS
    Adds every item of the given resource types, as they are in the tenant now, to the blueprint as a new version.

    .DESCRIPTION
    For blueprints that start small and grow: exports just -Types with the Reader app, classifies each type from
    export.log like a full check (a type that failed to export is reported and added nothing), and approves the items
    that are new against the blueprint with Approve-PEBlueprintChange, so the change gets a normal version and change
    record. Items of other types are never touched. Items with a duplicate key (Ambiguous) cannot be added and are
    counted in the result. Types the blueprint already holds items of are refused unless -AllowExistingTypes; then only
    items the blueprint lacks are added (nothing is changed or removed).

    This makes the tenant's current state the approved state for those types: review before adding admin roles, PIM
    settings or entitlement packages. -WhatIf stops after the export and reports what would be added.

    Returns Version (the new blueprint version, $null with -WhatIf or when nothing was new), Added (per type), Skipped
    (Ambiguous items per type), NotChecked (types that did not export) and Path (the export folder).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z][A-Za-z0-9]{2,80}\z')]
        [string[]]$Types,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [switch]$AllowExistingTypes,

        # Run although the pinned Microsoft365DSC is not the version the blueprint was built with.
        [switch]$AcceptModuleChange,

        # The tenant to read the items from. The blueprint is built from the master, so a replica is refused.
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [scriptblock]$ExportScript,

        [string]$TargetTenantId,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $Types = @($Types | Sort-Object -Unique)
    if ((Get-PETenant -Slug $Tenant -DataRoot $root).Role -ne 'Master')
    {
        throw "Tenant '$Tenant' is a replica. The blueprint is built from the master tenant; add types from there."
    }
    $known = @(Get-PEKnownResourceType)
    if ($known.Count -gt 0)
    {
        $unknown = @($Types | Where-Object { $known -inotcontains $_ })
        if ($unknown.Count -gt 0)
        {
            throw "Not DSC resource types in the pinned Microsoft365DSC: $($unknown -join ', ')."
        }
    }
    $current = Get-PEBlueprint -Name $Name -DataRoot $root
    Assert-PEModuleVersion -BlueprintName $Name -AcceptModuleChange:$AcceptModuleChange -DataRoot $root
    $held = @($Types | Where-Object { $type = $_; @($current.Records | Where-Object { $_.ResourceType -ieq $type }).Count -gt 0 })
    if ($held.Count -gt 0 -and -not $AllowExistingTypes)
    {
        throw "Blueprint '$Name' already holds items of $($held -join ', '). Pass -AllowExistingTypes to add only the items it lacks."
    }

    $outputPath = Join-Path $root ('exports\blueprint-add-' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    if ($ExportScript)
    {
        $exportPath = [string](@(& $ExportScript @{ Components = [string[]]$Types; OutputPath = $outputPath })[-1])
    }
    else
    {
        $tool = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\Export-M365DscTenant.ps1'
        Invoke-PEExportToolProcess -ArgumentList ([string[]]@('-NoProfile', '-File', $tool, '-Role', 'Reader', '-Components', ($Types -join ','), '-OutputPath', $outputPath) + [string[]]@($(if ($Tenant -ne 'master') { '-Tenant', $Tenant })))
        $exportPath = $outputPath
    }

    $tenantId = $TargetTenantId
    if (-not $tenantId -and -not $ExportScript) { $tenantId = Get-PEReaderTenantId -Tenant $Tenant }
    if (-not $tenantId) { $tenantId = 'unknown' }
    $fresh = New-PEStateFromExport -Path $exportPath -TenantId $tenantId -WarningAction SilentlyContinue
    $newRecords = @(@($fresh.Records) | Where-Object { $type = $_.ResourceType; @($Types | Where-Object { $_ -ieq $type }).Count -gt 0 })
    $notChecked = @(@($fresh.NotChecked) | Where-Object { $null -ne $_ -and $Types -icontains [string]$_.ResourceType })
    # A master state made of the whole blueprint plus the new items, so only the new items read as changes.
    $existingKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($current.Records)) { [void]$existingKeys.Add((Get-PEMatchKey -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key))) }
    $additions = @($newRecords | Where-Object { [string]::IsNullOrEmpty([string]$_.Key) -or -not $existingKeys.Contains((Get-PEMatchKey -ResourceType ([string]$_.ResourceType) -Key ([string]$_.Key))) })
    $meta = @{ TenantId = $tenantId; ExportedAt = (Get-PEMetaValue -Meta $fresh.Meta -Name 'ExportedAt'); Source = $exportPath }
    $master = New-PEState -Records @(@($current.Records) + $additions) -NotChecked @(@($current.NotChecked) + $notChecked) -Meta $meta
    $changes = @(Get-PEBlueprintChange -Name $Name -MasterState $master -DataRoot $root)
    $accept = @($changes | Where-Object { $_.Kind -eq 'Missing' -and $Types -icontains [string]$_.ResourceType })
    $skipped = @($changes | Where-Object { $_.Kind -eq 'Ambiguous' -and $Types -icontains [string]$_.ResourceType })

    $summary = [pscustomobject]@{
        Version    = $null
        Added      = @($accept | Group-Object ResourceType | Sort-Object Name | ForEach-Object { [pscustomobject]@{ ResourceType = $_.Name; Items = $_.Count } })
        Skipped    = @($skipped | Group-Object ResourceType | Sort-Object Name | ForEach-Object { [pscustomobject]@{ ResourceType = $_.Name; Ambiguous = $_.Count } })
        NotChecked = @($notChecked | ForEach-Object { [pscustomobject]@{ ResourceType = [string]$_.ResourceType; Reason = [string]$_.Reason } })
        Path       = $exportPath
    }
    if ($accept.Count -eq 0)
    {
        Write-Warning "Nothing to add to blueprint '$Name': no new items of $($Types -join ', ')."
        return $summary
    }
    if ($PSCmdlet.ShouldProcess("blueprint '$Name'", "Add $($accept.Count) item(s) of $($Types.Count) type(s) as a new version"))
    {
        $summary.Version = Approve-PEBlueprintChange -Name $Name -MasterState $master -Accept $accept -Reason $Reason -DataRoot $root
    }
    return $summary
}
