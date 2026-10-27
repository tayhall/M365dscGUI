function Get-PETenantExportState
{
    <#
    .SYNOPSIS
    Reads a tenant through DSC's export and returns it as a State: export, parse, normalise, classify from export.log.

    .DESCRIPTION
    Used by Invoke-PEFullCheck and Invoke-PEStandardCheck. Components that export.log reports as Failed or Incomplete go to
    NotChecked with the reason. A type -Blueprint holds records of, with nothing in the export and no log entry, is NotChecked
    ('not in export log', or 'no export log' when the log is missing), so it cannot read as Missing. The export goes to
    data\exports\<CheckId>. Returns State, ExportPath, ExportedAt, TenantId and LogWarnings.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Blueprint,

        [Parameter(Mandatory)]
        [string[]]$Workloads,

        [Parameter(Mandatory)]
        [string]$CheckId,

        [Parameter(Mandatory)]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$Root,

        [scriptblock]$ExportScript,

        # Tenant id of the exported (target) tenant. Default: TenantId of the Reader app registration; 'unknown' when
        # -ExportScript is used without this parameter. Never taken from the blueprint.
        [string]$TargetTenantId
    )

    $outputPath = Join-Path $Root ('exports\' + $CheckId)
    if ($ExportScript)
    {
        $exportPath = [string](@(& $ExportScript @{ Workloads = $Workloads; OutputPath = $outputPath })[-1])
    }
    else
    {
        $exportArguments = Get-PEExportToolArgument -Workloads $Workloads -OutputPath $outputPath -Tenant $Tenant
        Invoke-PEExportToolProcess -ArgumentList $exportArguments
        $exportPath = $outputPath
    }

    $exportFile = Find-PEExportFile -Path $exportPath
    $exportedAt = (Get-Item -LiteralPath $exportFile).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

    # The target's tenant id never comes from the blueprint.
    $tenantId = $TargetTenantId
    if (-not $tenantId -and -not $ExportScript)
    {
        $tenantId = Get-PEReaderTenantId -Tenant $Tenant
    }
    if (-not $tenantId)
    {
        $tenantId = 'unknown'
    }
    $records = @(Read-PEExport -Path $exportFile -TenantId $tenantId | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ -ExportedAt $exportedAt })

    $logPath = Join-Path $exportPath 'export.log'
    $hasLog = Test-Path -LiteralPath $logPath -PathType Leaf
    $logWarnings = [System.Collections.Generic.List[string]]::new()
    $entries = @(Read-PEExportLog -Path $logPath -Warnings $logWarnings)

    $notChecked = [System.Collections.Generic.List[object]]::new()
    $named = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $failed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries)
    {
        [void]$named.Add($entry.ResourceType)
        if ($entry.Status -in 'Failed', 'Incomplete')
        {
            # Incomplete: the component started but never finished, so its (partial) records cannot be trusted.
            [void]$failed.Add($entry.ResourceType)
            $notChecked.Add([pscustomobject]@{ ResourceType = $entry.ResourceType; Reason = $entry.Reason })
        }
    }

    # Blueprint types with nothing in the export and no Ok log entry cannot be judged Missing.
    $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $records)
    {
        [void]$present.Add([string]$record.ResourceType)
    }
    $gapReason = if ($hasLog) { 'not in export log' } else { 'no export log' }
    foreach ($type in @($Blueprint.Records | ForEach-Object { [string]$_.ResourceType } | Sort-Object -Unique))
    {
        if ($present.Contains($type) -or $failed.Contains($type) -or $named.Contains($type))
        {
            continue
        }
        $notChecked.Add([pscustomobject]@{ ResourceType = $type; Reason = $gapReason })
    }

    $meta = @{
        TenantId   = $tenantId
        ExportedAt = $exportedAt
        Source     = $exportPath
        ExportLog  = $(if ($hasLog) { 'present' } else { 'missing' })
        ModuleVersion = (Get-PEPinnedVersion -Name Microsoft365DSC)
        TenantSlug = $Tenant
    }
    [pscustomobject]@{
        State       = (New-PEState -Records $records -NotChecked @($notChecked) -Meta $meta)
        ExportPath  = $exportPath
        ExportedAt  = $exportedAt
        TenantId    = $tenantId
        LogWarnings = @($logWarnings)
    }
}

function New-PECheckId
{
    # CheckId: sortable UTC timestamp; on a collision (same second) take the next free second.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Root
    )

    $moment = [datetime]::UtcNow
    while (Test-Path -LiteralPath (Join-Path $Root ('checks\' + $moment.ToString('yyyyMMdd-HHmmss'))))
    {
        $moment = $moment.AddSeconds(1)
    }
    return $moment.ToString('yyyyMMdd-HHmmss')
}
