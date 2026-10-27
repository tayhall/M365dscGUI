function Invoke-PEFullCheck
{
    <#
    .SYNOPSIS
    Exports the tenant, compares it with a blueprint and saves the result as checks\<CheckId>\result.json.

    .DESCRIPTION
    -ExportScript produces the export and returns the path of the export folder; it is called with the named values
    Workloads and OutputPath. Checks always use the Reader app registration. The default runs tools\Export-M365DscTenant.ps1 in a child process, which writes
    export.ps1 and export.log into OutputPath (data\exports\<CheckId>).

    Components are classified from export.log (Read-PEExportLog): Failed ones go to the target's NotChecked list with the
    error, so they never produce Missing findings. An Ok component with no instances is genuinely empty, so the
    blueprint's records of that type become Missing. If export.log is missing the check is degraded: every blueprint
    type with no records in the export becomes NotChecked with the reason 'no export log' (State.Meta.ExportLog is
    'missing'). When the log exists, a blueprint type that the log never mentions becomes NotChecked 'not in export log'
    (for example a workload that was not exported).

    The state holds normalised records only (ignored properties such as ids and credentials are removed), so the result
    carries no secrets. result.json is written once.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [string[]]$Workloads = (Get-PEDefaultWorkload),

        [scriptblock]$ExportScript,

        # Tenant id of the exported (target) tenant. Default: TenantId of the Reader app registration; 'unknown' when
        # -ExportScript is used without this parameter. Never taken from the blueprint.
        [string]$TargetTenantId,

        # Run although the pinned Microsoft365DSC is not the version the blueprint was built with (to review the effect of an upgrade as drift).
        [switch]$AcceptModuleChange,

        # Which tenant to read (see Get-PETenant); the first tenant is 'master'.
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    Assert-PEBlueprintNotStandard -Name $BlueprintName -Action 'run a full check against it (use Invoke-PEStandardCheck)' -DataRoot $root
    $blueprint = Get-PEBlueprint -Name $BlueprintName -DataRoot $root
    Assert-PEModuleVersion -BlueprintName $BlueprintName -AcceptModuleChange:$AcceptModuleChange -DataRoot $root
    $blueprintVersion = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $BlueprintName -DataRoot $root))[-1]

    # CheckId: sortable UTC timestamp; on a collision (same second) take the next free second.
    $moment = [datetime]::UtcNow
    while (Test-Path -LiteralPath (Join-Path $root ('checks\' + $moment.ToString('yyyyMMdd-HHmmss'))))
    {
        $moment = $moment.AddSeconds(1)
    }
    $checkId = $moment.ToString('yyyyMMdd-HHmmss')

    $outputPath = Join-Path $root ('exports\' + $checkId)
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
    foreach ($type in @($blueprint.Records | ForEach-Object { [string]$_.ResourceType } | Sort-Object -Unique))
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
    $state = New-PEState -Records $records -NotChecked @($notChecked) -Meta $meta

    $decisions = @(Get-PEDecision -DataRoot $root -Tenant $Tenant)
    $findings = @(Compare-PEState -Blueprint $blueprint -Target $state -Decisions $decisions)

    $document = [ordered]@{
        CheckId          = $checkId
        Kind             = 'Full'
        TenantSlug       = $Tenant
        BlueprintName    = $BlueprintName
        BlueprintTenantId = [string](Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId')
        CrossTenant      = (Test-PECrossTenant -BlueprintTenantId (Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId') -TargetTenantId $tenantId)
        BlueprintVersion = $blueprintVersion
        Path             = $exportPath
        LogWarnings      = @($logWarnings)
        Findings         = $findings
        State            = $state
    }
    Write-PEJsonNew -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document

    [pscustomobject]@{
        CheckId  = $checkId
        Findings = $findings
        LogWarnings = @($logWarnings)
        State    = $state
        Path     = $exportPath
    }
}
