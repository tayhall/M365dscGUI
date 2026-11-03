function Get-PEDriftReportData
{
    <#
    .SYNOPSIS
    Turns the findings of Invoke-PEExportComparison into the plain data the HTML drift report shows.

    .DESCRIPTION
    Returns [pscustomobject]@{ Meta; Totals; Items }. An item is one open finding:
      Id            '<Action>|<ResourceType>|<Key>' for an actionable finding, '<Kind>|<ResourceType>|<Key>' for any other
      Action        Create (Missing in Dev), Update (Changed), Remove (only in Dev), or $null for every other kind
      Approvable    true only when New-PERectifyPlan accepts the finding (the engine's own rules), and, for a Remove, the
                    blueprint (PreProd) manages the type and the finding has no hint
      NotCompared   true for a finding that says something was not compared at all (Excluded, NotChecked, NotAvailable): information, not drift
      Reason        why it cannot be approved (the engine's message, one line), empty when it can
      Differences   @{ Property; Dev; PreProd } with display strings, cut at -MaxValueLength
      Props         every property of the record(s) behind the finding, for the single-resource view: @{ Property; Source; Target; State }
                    with display strings ($null where that side has no such property) and State different | excluded | same | ignored |
                    only-source | only-target ('ignored': both sides have it, the values look different, the engine does not compare it)
    Types is the record count of each resource type on both sides (@{ ResourceType; Workload; Source; Target }) for the totals, and
    Meta.WorkloadOrder the engine's workload order.
    Resources that match are only counted (Totals.Matching), never listed. Totals.Create/Update/Remove count approvable items;
    Totals.CannotApprove counts the other drift (Ambiguous, PossibleRename, refused by the engine); Totals.NotCompared counts the NotCompared items. Totals.Matching is the PreProd records without a finding.
    No comparison happens here: the findings are the engine's.

    Cost: every New-PERectifyPlan call indexes all records of the source and the blueprint, so asking once per finding would take
    minutes on a large export. The findings of one action are asked together, and a refused group is split in halves until the
    refused item is alone (as New-PEOfflineConfig does), so with few refusals it is a handful of calls.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [object]$Comparison,

        [Parameter(Mandatory)]
        [string]$Tenant,

        # @{ Run; ExportedAt; Fingerprint } of the PreProd (source) and Dev (target) exports, as New-PEApprovedList takes them.
        [Parameter(Mandatory)]
        [hashtable]$Source,

        [Parameter(Mandatory)]
        [hashtable]$Target,

        # Plain-text names of the two sides, shown in the page (the tenants behind PreProd and Dev in a pipeline).
        [ValidatePattern('\A[\w .()-]{1,40}\z')]
        [string]$SourceLabel = 'PreProd',

        [ValidatePattern('\A[\w .()-]{1,40}\z')]
        [string]$TargetLabel = 'Dev',

        [datetime]$GeneratedUtc = [datetime]::UtcNow,

        [ValidateRange(10, 100000)]
        [int]$MaxValueLength = 4000
    )

    $actionFor = @{ Missing = 'Create'; Changed = 'Update'; TargetOnly = 'Remove' }
    $display = {
        param ($value)
        if ($null -eq $value) { return '(none)' }
        $text = if ($value -is [string]) { $value } else { ConvertTo-Json -InputObject $value -Compress -Depth 6 }
        if ($text.Length -gt $MaxValueLength) { $text = $text.Substring(0, $MaxValueLength) + [string][char]0x2026 }
        $text
    }

    $blueprint = $Comparison.Blueprint
    $state = $Comparison.Check.State
    $managedTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($blueprint.Records)) { [void]$managedTypes.Add([string]$record.ResourceType) }

    # Pass 1: one entry per open finding; the cheap rules decide some of them, the rest wait for the engine.
    $entries = [System.Collections.Generic.List[object]]::new()
    $matchingTaken = 0
    foreach ($finding in @($Comparison.Findings | Where-Object { $_.State -eq 'Open' }))
    {
        $kind = [string]$finding.Kind
        $action = if ($actionFor.ContainsKey($kind)) { $actionFor[$kind] } else { $null }
        $key = [string]$finding.Key
        $reason = ''
        $ask = $false

        if ($null -eq $action)
        {
            $reason = if (-not [string]::IsNullOrWhiteSpace([string]$finding.Hint)) { [string]$finding.Hint } else { $kind }
        }
        elseif ([string]::IsNullOrEmpty($key))
        {
            $reason = "$kind finding without a key"
        }
        elseif ($kind -eq 'TargetOnly' -and -not $managedTypes.Contains([string]$finding.ResourceType))
        {
            $reason = "type '$($finding.ResourceType)' has no records in PreProd's export, so nothing says Dev should not have these"
        }
        elseif (-not [string]::IsNullOrEmpty([string]$finding.Hint))
        {
            $reason = [string]$finding.Hint
        }
        else
        {
            $ask = $true
        }

        $entries.Add([pscustomobject]@{ Finding = $finding; Kind = $kind; Action = $action; Key = $key; Ask = $ask; Approvable = $false; Reason = $reason
                NotCompared = ($kind -in 'Excluded', 'NotChecked', 'NotAvailable') })

        # A record of PreProd that has a finding does not match: Missing and Changed are one record each, Ambiguous holds BlueprintCount.
        if ($kind -in 'Missing', 'Changed') { $matchingTaken++ }
        elseif ($kind -eq 'Ambiguous' -and $null -ne $finding.PSObject.Properties['BlueprintCount']) { $matchingTaken += [int]$finding.BlueprintCount }
    }

    # Pass 2: ask the engine per action, in groups.
    $ask = {
        param ([object[]]$group)
        $arguments = @{ Source = $state; Blueprint = $blueprint }
        if ($group[0].Action -eq 'Remove')
        {
            $arguments.Decisions = @($group | ForEach-Object {
                    [pscustomobject]@{ Kind = 'Remove'; ResourceType = [string]$_.Finding.ResourceType; Key = $_.Key; Property = $null; Value = $null; Reason = 'drift report (not stored)'; At = '2026-01-01T00:00:00.000Z' }
                })
        }
        try
        {
            New-PERectifyPlan -Findings @($group | ForEach-Object { $_.Finding }) -Action $group[0].Action @arguments | Out-Null
            foreach ($entry in $group) { $entry.Approvable = $true }
        }
        catch
        {
            if ($group.Count -eq 1)
            {
                $group[0].Reason = (([string]$_.Exception.Message) -split "`r?`n")[0].Trim()
            }
            else
            {
                $half = [int][Math]::Ceiling($group.Count / 2)
                & $ask @($group[0..($half - 1)])
                & $ask @($group[$half..($group.Count - 1)])
            }
        }
    }
    foreach ($action in 'Create', 'Update', 'Remove')
    {
        $group = @($entries | Where-Object { $_.Ask -and $_.Action -eq $action })
        if ($group.Count) { & $ask $group }
    }

    $items = foreach ($entry in $entries)
    {
        $props = @()
        $sourceMap = Get-PEReportPropertyMap -Record $entry.Finding.BlueprintRecord
        $targetMap = Get-PEReportPropertyMap -Record $entry.Finding.TargetRecord
        if ($sourceMap.Count -gt 0 -or $targetMap.Count -gt 0)
        {
            $different = Get-PEReportPropertyName -Difference @($entry.Finding.Differences)
            $excluded = Get-PEReportPropertyName -Difference @(@($entry.Finding.ExcludedDifferences) + @($entry.Finding.AcceptedDifferences))
            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($name in @($sourceMap.Keys) + @($targetMap.Keys)) { if (-not $names.Contains($name)) { $names.Add($name) } }
            $props = @(foreach ($name in $names)
                {
                    $hasSource = $sourceMap.Contains($name)
                    $hasTarget = $targetMap.Contains($name)
                    $sourceText = if ($hasSource) { & $display $sourceMap[$name] } else { $null }
                    $targetText = if ($hasTarget) { & $display $targetMap[$name] } else { $null }
                    $state = if (-not $hasTarget) { 'only-source' }
                    elseif (-not $hasSource) { 'only-target' }
                    elseif ($different.Contains($name)) { 'different' }
                    elseif ($excluded.Contains($name)) { 'excluded' }
                    elseif ($sourceText -ceq $targetText) { 'same' }
                    else { 'ignored' }
                    [pscustomobject][ordered]@{ Property = $name; Source = $sourceText; Target = $targetText; State = $state }
                })
        }
        $differences = @(foreach ($difference in @($entry.Finding.Differences | Where-Object { $null -ne $_ }))
            {
                [pscustomobject][ordered]@{ Property = [string]$difference.Property; Dev = (& $display $difference.Target); PreProd = (& $display $difference.Blueprint) }
            })
        $idLead = if ($entry.Action) { $entry.Action } else { $entry.Kind }
        [pscustomobject][ordered]@{
            Id           = "$idLead|$($entry.Finding.ResourceType)|$($entry.Key)"
            Action       = $entry.Action
            Kind         = $entry.Kind
            ResourceType = [string]$entry.Finding.ResourceType
            Key          = $entry.Key
            Workload     = [string]$entry.Finding.Workload
            Approvable   = $entry.Approvable
            NotCompared  = $entry.NotCompared
            Reason       = $(if ($entry.Approvable) { '' } else { $entry.Reason })
            Differences  = $differences
            Props        = $props
        }
    }
    $items = @($items)

    $sourceRecords = @($Comparison.SourceState.Records).Count
    $removeOnly = @($items | Where-Object { $_.Kind -eq 'TargetOnly' }).Count
    $approvableItems = @($items | Where-Object Approvable)
    $totals = [pscustomobject][ordered]@{
        Total         = ($sourceRecords + $removeOnly)
        Matching      = [Math]::Max(0, $sourceRecords - $matchingTaken)
        Create        = @($approvableItems | Where-Object Action -EQ 'Create').Count
        Update        = @($approvableItems | Where-Object Action -EQ 'Update').Count
        Remove        = @($approvableItems | Where-Object Action -EQ 'Remove').Count
        CannotApprove = @($items | Where-Object { -not $_.Approvable -and -not $_.NotCompared }).Count
        NotCompared   = @($items | Where-Object NotCompared).Count
    }

    # Record counts per type on both sides, for the totals (types that only have drift items are listed too).
    $typeCounts = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $countType = {
        param ([string]$type, [string]$side)
        if (-not $typeCounts.ContainsKey($type)) { $typeCounts[$type] = @{ Source = 0; Target = 0 } }
        if ($side) { $typeCounts[$type][$side]++ }
    }
    foreach ($record in @($Comparison.SourceState.Records)) { & $countType ([string]$record.ResourceType) 'Source' }
    foreach ($record in @($Comparison.Check.State.Records)) { & $countType ([string]$record.ResourceType) 'Target' }
    foreach ($item in $items) { & $countType $item.ResourceType '' }
    $workloadOrder = @(@(Get-PEWorkloadDefinition | ForEach-Object { [string]$_.Name }) + 'Other' | Select-Object -Unique)
    $types = @(foreach ($type in $typeCounts.Keys)
        {
            $workload = Get-PEWorkload -ResourceType $type
            [pscustomobject][ordered]@{ ResourceType = $type; Workload = $workload; Source = [int]$typeCounts[$type].Source; Target = [int]$typeCounts[$type].Target }
        }) | Sort-Object { $i = [array]::IndexOf($workloadOrder, $_.Workload); if ($i -lt 0) { 999 } else { $i } }, ResourceType

    $side = { param ($h) [pscustomobject][ordered]@{ Run = [string]$h.Run; ExportedAt = [string]$h.ExportedAt; Fingerprint = [string]$h.Fingerprint } }
    $reportId = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes([string]$Source.Fingerprint + [string]$Target.Fingerprint))).ToLowerInvariant()
    [pscustomobject][ordered]@{
        Meta   = [pscustomobject][ordered]@{
            Tenant        = $Tenant
            SourceLabel   = $SourceLabel
            TargetLabel   = $TargetLabel
            Source        = & $side $Source
            Target        = & $side $Target
            ModuleVersion = (Get-PEPinnedVersion -Name Microsoft365DSC)
            GeneratedUtc  = $GeneratedUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            ReportId      = $reportId
            WorkloadOrder = $workloadOrder
        }
        Totals = $totals
        Types  = @($types)
        Items  = @($items | Sort-Object ResourceType, Key, Kind)
    }
}
