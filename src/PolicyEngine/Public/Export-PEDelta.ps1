function Export-PEDelta
{
    <#
    .SYNOPSIS
    Exports only the objects named by the given findings and returns them as a state (a delta). A delta exports
    objects that EXIST in the exporting (Reader) tenant: TargetOnly findings, or objects new in a master. A Missing
    object does not exist there, so its export comes back empty or incomplete and the call throws; Rectify restores a
    Missing object from its blueprint record and needs no delta.

    .DESCRIPTION
    Findings must be Missing, TargetOnly or target-side PossibleRename (TargetRecord set: the object exists in the
    tenant, as in a quick scan's conservative rename rule) with a key; any other Kind (blueprint-side PossibleRename,
    Changed, Ambiguous, NotChecked, ...) throws before anything is exported. Requests are grouped by type and key (case-insensitive, duplicates
    dropped).

    Per type: when the type has a safe key filter (Private\Delta.ps1, $script:PEDeltaFilterProperty; v1 AADGroup on
    DisplayName) and Microsoft365DSC accepts a Filter for it (Test-M365DSCResourceProperty), one export runs per key
    with -Components <type> -Filters @{ <type> = "DisplayName eq '<key>'" } (single quotes doubled). Otherwise one
    export of the whole type runs. Either way only records whose (type, key) was requested are kept.

    Each export goes through the same log checks as a Full check: export.log must exist and report the type Ok; a
    missing log, a type the log does not mention, or a Failed / Incomplete type throws (never an empty delta).

    A requested key absent from the export is reported with a warning and listed in State.Meta.NotFound.

    -WholeType exports every requested type whole, never with a key filter. Use it to confirm that keys are ABSENT
    (Invoke-PERectify's recheck after a Remove): a filtered export of an object that does not exist logs no completion
    mark and throws, while a whole-type export completes and simply lacks the key (listed in Meta.NotFound).

    -ExportScript is called with the named parameters -Components <string[]>, -Filters <hashtable> and -OutputPath
    and returns the export folder. The default runs tools\Export-M365DscTenant.ps1 with the Reader app.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Findings,

        [switch]$WholeType,

        [scriptblock]$ExportScript,

        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [string]$DataRoot
    )

    # 1. Validate and group the requests.
    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    $requests = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new($comparer)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($finding in $Findings)
    {
        if ($null -eq $finding)
        {
            continue
        }
        # A PossibleRename built from a target record (TargetRecord set) is an object that exists in the tenant, so a
        # delta can export it; a blueprint-side one (no TargetRecord) does not exist there.
        $targetSideRename = $finding.Kind -eq 'PossibleRename' -and $null -ne $finding.PSObject.Properties['TargetRecord'] -and $null -ne $finding.TargetRecord
        if ($finding.Kind -notin 'Missing', 'TargetOnly' -and -not $targetSideRename)
        {
            throw "Export-PEDelta accepts only Missing, TargetOnly and target-side PossibleRename findings; got $($finding.Kind) for $($finding.ResourceType) '$($finding.Key)'."
        }
        $type = [string]$finding.ResourceType
        $key = [string]$finding.Key
        if ([string]::IsNullOrWhiteSpace($type) -or [string]::IsNullOrWhiteSpace($key))
        {
            throw "Export-PEDelta needs a ResourceType and a Key on every finding."
        }
        # Resource names are plain identifiers; anything else must not reach a path or the export command line.
        if ($type -notmatch '^[A-Za-z0-9]+$')
        {
            throw "Invalid resource type name '$type'."
        }
        if (-not $seen.Add((Get-PEMatchKey -ResourceType $type -Key $key)))
        {
            continue
        }
        if (-not $requests.ContainsKey($type))
        {
            $requests[$type] = [System.Collections.Generic.List[string]]::new()
        }
        $requests[$type].Add($key)
    }
    if ($requests.Count -eq 0)
    {
        throw 'Export-PEDelta was given no findings to export.'
    }

    $root = Get-PEDataRoot -Override $DataRoot
    $moment = [datetime]::UtcNow
    while (Test-Path -LiteralPath (Join-Path $root ('exports\delta-' + $moment.ToString('yyyyMMdd-HHmmss'))))
    {
        $moment = $moment.AddSeconds(1)
    }
    $deltaRoot = Join-Path $root ('exports\delta-' + $moment.ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $deltaRoot -Force | Out-Null

    $tenantId = if ($ExportScript) { 'unknown' } else { Get-PEReaderTenantId -Tenant $Tenant }
    if (-not $tenantId)
    {
        $tenantId = 'unknown'
    }

    # 2. Plan the exports: per key with a filter, or the whole type.
    $filterable = if ($WholeType) { @() } else { @($requests.get_Keys() | Where-Object { $null -ne (Get-PEDeltaFilter -ResourceType $_ -Key 'x') }) }
    $support = if ($filterable.Count -gt 0) { Test-PEResourceFilterSupport -ResourceType $filterable } else { @{} }
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $requests.get_Keys())
    {
        if ($support.ContainsKey($type) -and $support[$type])
        {
            foreach ($key in $requests[$type])
            {
                $plan.Add([pscustomobject]@{ Type = $type; Keys = @($key); Filters = @{ $type = (Get-PEDeltaFilter -ResourceType $type -Key $key) } })
            }
        }
        else
        {
            $plan.Add([pscustomobject]@{ Type = $type; Keys = @($requests[$type]); Filters = @{} })
        }
    }

    # A GUID reference that DSC exports (Data\References.psd1, ResolveGuid) is resolved with the parent's Id, so the parent type is
    # exported first, whole, for its Ids only: its records are not kept.
    $referenceMap = @{}
    $referenceSteps = foreach ($parent in @($plan | ForEach-Object { Get-PEGuidParentType -ResourceType $_.Type } | Sort-Object -Unique))
    {
        if (-not $requests.ContainsKey($parent))
        {
            [pscustomobject]@{ Type = $parent; Keys = @(); Filters = @{}; ReferenceOnly = $true }
        }
    }
    if (@($referenceSteps).Count -gt 0)
    {
        $plan.InsertRange(0, [object[]]@($referenceSteps))
    }

    # 3. Run them, check each log, keep only requested records.
    $records = [System.Collections.Generic.List[object]]::new()
    $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $logWarnings = [System.Collections.Generic.List[string]]::new()
    $sources = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $plan.Count; $i++)
    {
        $step = $plan[$i]
        $outputPath = Join-Path $deltaRoot ('{0:d3}-{1}' -f ($i + 1), $step.Type)
        $arguments = @{ Components = [string[]]@($step.Type); Filters = $step.Filters; OutputPath = $outputPath }
        if ($ExportScript)
        {
            $exportPath = [string](@(& $ExportScript @arguments)[-1])
        }
        else
        {
            $exportPath = [string](@(Invoke-PEDeltaExportTool @arguments -Tenant $Tenant)[-1])
        }
        $sources.Add($exportPath)

        $logPath = Join-Path $exportPath 'export.log'
        if (-not (Test-Path -LiteralPath $logPath -PathType Leaf))
        {
            throw "Delta export of $($step.Type) has no export log ($logPath); its result cannot be trusted."
        }
        $entry = @(Read-PEExportLog -Path $logPath -Warnings $logWarnings) | Where-Object { $_.ResourceType -ieq $step.Type } | Select-Object -First 1
        if ($step.PSObject.Properties['ReferenceOnly'])
        {
            if ($null -ne $entry -and $entry.Status -eq 'Ok')
            {
                $null = @(Read-PEExport -Path (Find-PEExportFile -Path $exportPath) -TenantId $tenantId -ReferenceMap $referenceMap)
            }
            else
            {
                $logWarnings.Add("Reference export of $($step.Type) did not complete; GUID references to it stay unresolved.")
            }
            continue
        }
        if ($null -eq $entry)
        {
            throw "Delta export of $($step.Type): type not in export log ($logPath)."
        }
        if ($entry.Status -ne 'Ok')
        {
            $message = "Delta export of $($step.Type) $($entry.Status): $($entry.Reason)"
            if ($entry.Status -eq 'Incomplete' -and $step.Filters.Count -gt 0)
            {
                # Seen live (AADGroup, Microsoft365DSC 2.26.1015.1): a filter that matches nothing logs no completion
                # mark, so the log cannot tell an absent object from a cut-off export. Fail safe.
                $message += " (filter: $($step.Filters[$step.Type]); a filter that matches no object also logs no completion mark, so the object may not exist in the tenant)"
            }
            throw $message
        }

        $exportFile = Find-PEExportFile -Path $exportPath
        # The export file's write time: conditional ignore paths (When = PastExport) compare dates with it. It is never
        # later than the delta's Meta.ExportedAt (taken at the end).
        $fileExportedAt = (Get-Item -LiteralPath $exportFile).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($key in $step.Keys)
        {
            [void]$wanted.Add((Get-PEMatchKey -ResourceType $step.Type -Key $key))
        }
        foreach ($raw in @(Read-PEExport -Path $exportFile -TenantId $tenantId -ReferenceMap $referenceMap))
        {
            if ([string]$raw.ResourceType -ine $step.Type)
            {
                continue
            }
            $record = ConvertTo-PENormalizedRecord -Record $raw -ExportedAt $fileExportedAt
            if ([string]::IsNullOrWhiteSpace([string]$record.Key))
            {
                continue
            }
            $matchKey = Get-PEMatchKey -ResourceType $step.Type -Key ([string]$record.Key)
            # Only the keys this call asked for are kept (a filtered call: its one key; a whole-type call: all of the
            # type's keys), so records never repeat across calls even if a filter were ignored. Two records with the same key are both kept:
            # that is a real duplicate in the tenant and must stay visible (Ambiguous when compared).
            if ($wanted.Contains($matchKey))
            {
                [void]$found.Add($matchKey)
                $records.Add($record)
            }
        }
    }

    # 4. Requested keys absent from the export are reported, never dropped silently.
    $notFound = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $requests.get_Keys())
    {
        foreach ($key in $requests[$type])
        {
            if (-not $found.Contains((Get-PEMatchKey -ResourceType $type -Key $key)))
            {
                Write-Warning "Delta export: $type '$key' was not found in the export."
                $notFound.Add([pscustomobject]@{ ResourceType = $type; Key = $key })
            }
        }
    }

    $meta = @{
        Kind        = 'Delta'
        TenantId    = $tenantId
        ExportedAt  = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Source      = $deltaRoot
        Exports     = @($sources)
        Requested   = @(foreach ($type in $requests.get_Keys()) { foreach ($key in $requests[$type]) { [pscustomobject]@{ ResourceType = $type; Key = $key } } })
        NotFound    = @($notFound)
        LogWarnings = @($logWarnings)
    }
    New-PEState -Records @($records) -NotChecked @() -Meta $meta
}
