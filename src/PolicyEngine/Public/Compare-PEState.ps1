function Compare-PEState
{
    <#
    .SYNOPSIS
    Compares a target state against the blueprint state and returns drift findings.

    .DESCRIPTION
    Records match on (ResourceType, Key), case-insensitively. Rules, in order:
    - A type listed in Data\ExcludedTypes.psd1 (and not named in -IncludeTypes) is not compared: its records are
      ignored on both sides (no Missing, TargetOnly, Changed, Ambiguous or Unkeyed finding) and it yields ONE finding
      of Kind 'Excluded' (Key $null, Hint = the reason from the data file, BlueprintCount / TargetCount = the counts of
      excluded records) when it has records on either side or is in either NotChecked list. Excluded wins over
      NotChecked and NotAvailable: an excluded type that also failed to export yields only the Excluded finding.
      A type with a RecordRule (EXOManagementRoleEntry: KeepCustomRoleEntries) is excluded record by record, each side
      by its own records: the kept records are compared as usual (and NotChecked/NotAvailable apply to the type), and
      the Excluded finding appears only when at least one record was left out.
    - A type in either NotChecked list yields one finding per type and no other finding for that type's records:
      NotAvailable when both lists name it, otherwise NotChecked (Hint carries the reason). A type that failed only
      on the blueprint side is also NotChecked: without blueprint data every target record would look TargetOnly.
    - A record with no key yields one Unkeyed finding per record (per side).
    - A key that appears more than once in either state yields one Ambiguous finding and no other finding.
    - Blueprint only: Missing. Target only: TargetOnly. Both with different properties: Changed with Differences.
    - Rename detection (conservative, no one-to-one pairing): similarity = equal properties / union of property
      names, ignoring properties empty on both sides and Ensure. Any Missing or TargetOnly record with at least one
      counterpart of the opposite kind and same type scoring >= RenameThreshold becomes PossibleRename (never
      removable) with Hint 'Possible rename of <key1>, <key2>' naming every such counterpart in descending
      similarity (at most five, then ' and N more'). PossibleRename findings carry no Differences. When a type has
      more than $script:PERenameMaxPairs Missing x TargetOnly pairs the check is skipped: records keep their Kind
      and get Hint 'Rename check skipped: too many candidates'. Target records named by an Unmanaged decision take no
      part in rename detection (and do not count towards the pair bound): they stay TargetOnly with no Hint, so a
      lookalike the user chose to keep never blocks the Missing record from being created.
    - Noise decisions (ResourceType + Property, optionally Key) remove a Changed difference whose TARGET value equals
      the decision Value; a Changed finding with no differences left is dropped.
    - An Unmanaged decision that names a REPLICA tenant (Tenant set and not 'master') also sets State 'Unmanaged' on Missing and Changed findings of
      that key: the item is deliberately not expected, or not kept equal, in that tenant (a tenant-specific object). A decision without a tenant, or
      for the master, never hides a Missing or Changed finding.
    - Unmanaged decisions set State 'Unmanaged' only on TargetOnly findings and PossibleRename findings built from
      a target record, with that ResourceType and Key. A stale decision never hides a Missing or Changed finding.
    - Remove decisions do not affect comparison (they are used by Rectify).
    - Ignore paths of Data\IgnoredProperties.psd1 (dotted, for example 'ScheduleInfo.startDateTime', or conditional
      @{ Path; When = 'PastExport' }) are applied to both records of a matched pair before their properties are
      compared, so a blueprint stored before the entry was added does not report the ignored member as Changed. (New
      records already lose it in ConvertTo-PENormalizedRecord.) A conditional path uses each STATE's own
      Meta.ExportedAt; on a side whose state has no ExportedAt the conditional paths are not applied.
    - Tenant-bound properties (Data\IgnoredProperties.psd1, TenantBound: ids generated per tenant, values naming the
      tenant's own objects) are left out of a matched pair when the target is a different tenant from the blueprint's
      (-CrossTenant Auto: both Meta.TenantId values known and different), so a dev tenant checked against a production
      blueprint does not report its own ids. Against the tenant the blueprint came from they are compared like any
      other property. -CrossTenant Yes / No forces either behaviour.
    - For a different tenant, a property that still differs is compared again with the target tenant's own short name (the
      first label of Meta.TenantId, only as the tenant's own label of a *.sharepoint.com or *.onmicrosoft.com host) replaced by the
      blueprint tenant's, so reply URLs and site addresses that differ only by the tenant's domain are not reported. Nothing else about the value is changed, and a
      difference that remains is reported with the target's original value. Ids that name no domain (GUIDs) are not used.
    -IncludeTypes names excluded types to compare anyway in this call (case-insensitive); a name that is not excluded
    is ignored with one warning.
    Output is sorted by ResourceType, Key, Kind. See Private\Compare.ps1 for the value equality rules and the
    BlueprintRecord / TargetRecord properties attached to findings.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object]$Blueprint,

        [Parameter(Mandatory)]
        [object]$Target,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Decisions = @(),

        [ValidateRange(0.0, 1.0)]
        [double]$RenameThreshold = 0.8,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$IncludeTypes = @(),

        [ValidateSet('Auto', 'Yes', 'No')]
        [string]$CrossTenant = 'Auto'
    )

    $isCrossTenant = switch ($CrossTenant)
    {
        'Yes' { $true }
        'No' { $false }
        default { Test-PECrossTenant -BlueprintTenantId (Get-PEMetaValue -Meta $Blueprint.Meta -Name 'TenantId') -TargetTenantId (Get-PEMetaValue -Meta $Target.Meta -Name 'TenantId') }
    }
    $tenantBoundTypes = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Another tenant's own domain name inside a value (reply URLs, site addresses) is not a difference: with both short names
    # known, a differing property is compared again with the target's name replaced by the blueprint's.
    $blueprintName = ''
    $targetName = ''
    if ($isCrossTenant)
    {
        $blueprintName = Get-PETenantShortName -TenantId (Get-PEMetaValue -Meta $Blueprint.Meta -Name 'TenantId')
        $targetName = Get-PETenantShortName -TenantId (Get-PEMetaValue -Meta $Target.Meta -Name 'TenantId')
        # Both names are needed: with one missing the other would be replaced by nothing.
        if (-not $blueprintName -or -not $targetName -or $blueprintName -ieq $targetName) { $blueprintName = ''; $targetName = '' }
    }

    $findings = [System.Collections.Generic.List[object]]::new()

    # 0. Excluded types (Data\ExcludedTypes.psd1, minus -IncludeTypes): their records are left out of the comparison
    # (whole types, or the records a RecordRule does not keep) and each such type gets one Excluded finding.
    $blueprintNotChecked = Get-PENotCheckedMap -NotChecked $Blueprint.NotChecked
    $targetNotChecked = Get-PENotCheckedMap -NotChecked $Target.NotChecked
    $skipTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $excluded = Get-PEExcludedTypeMap
    $unknownIncludes = [System.Collections.Generic.List[string]]::new()
    foreach ($type in @($IncludeTypes))
    {
        if (-not [string]::IsNullOrWhiteSpace($type) -and -not $excluded.Remove($type.Trim()))
        {
            $unknownIncludes.Add($type.Trim())
        }
    }
    if ($unknownIncludes.Count -gt 0)
    {
        Write-Warning "Compare-PEState -IncludeTypes: not excluded types (nothing to include): $($unknownIncludes -join ', ')."
    }
    $blueprintSelection = Select-PEComparedRecord -Records $Blueprint.Records -Excluded $excluded
    $targetSelection = Select-PEComparedRecord -Records $Target.Records -Excluded $excluded
    $blueprintRecordsCompared = $blueprintSelection.Kept
    $targetRecordsCompared = $targetSelection.Kept
    if ($excluded.Count -gt 0)
    {
        $seenTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($type in @($blueprintSelection.ExcludedCounts.get_Keys()) + @($targetSelection.ExcludedCounts.get_Keys()) + @($blueprintNotChecked.get_Keys()) + @($targetNotChecked.get_Keys()))
        {
            if (-not $excluded.ContainsKey($type) -or -not $seenTypes.Add($type))
            {
                continue
            }
            $entry = $excluded[$type]
            $bc = 0
            $tc = 0
            [void]$blueprintSelection.ExcludedCounts.TryGetValue($type, [ref]$bc)
            [void]$targetSelection.ExcludedCounts.TryGetValue($type, [ref]$tc)
            if ($entry.RecordRule)
            {
                # A record-level exclusion: the kept records are compared as usual (NotChecked applies to them), and
                # the Excluded finding appears only when records were left out.
                if ($bc + $tc -gt 0)
                {
                    $findings.Add((New-PEFinding -Kind 'Excluded' -ResourceType $type -Key $null -Workload (Get-PEWorkload -ResourceType $type) -Hint $entry.Reason -BlueprintCount $bc -TargetCount $tc))
                }
                continue
            }
            $findings.Add((New-PEFinding -Kind 'Excluded' -ResourceType $type -Key $null -Workload (Get-PEWorkload -ResourceType $type) -Hint $entry.Reason -BlueprintCount $bc -TargetCount $tc))
        }
        foreach ($type in $excluded.get_Keys())
        {
            if (-not $excluded[$type].RecordRule)
            {
                [void]$skipTypes.Add($type)
            }
        }
    }

    # 1. Types that could not be compared (an excluded type is already in $skipTypes: Excluded wins).
    foreach ($type in @($targetNotChecked.get_Keys()) + @($blueprintNotChecked.get_Keys()))
    {
        if (-not $skipTypes.Add($type))
        {
            continue
        }
        $inBlueprint = $blueprintNotChecked.ContainsKey($type)
        $inTarget = $targetNotChecked.ContainsKey($type)
        if ($inBlueprint -and $inTarget)
        {
            $findings.Add((New-PEFinding -Kind 'NotAvailable' -ResourceType $type -Key $null -Workload (Get-PEWorkload -ResourceType $type) -Hint $targetNotChecked[$type]))
        }
        elseif ($inTarget)
        {
            $findings.Add((New-PEFinding -Kind 'NotChecked' -ResourceType $type -Key $null -Workload (Get-PEWorkload -ResourceType $type) -Hint $targetNotChecked[$type]))
        }
        else
        {
            $findings.Add((New-PEFinding -Kind 'NotChecked' -ResourceType $type -Key $null -Workload (Get-PEWorkload -ResourceType $type) -Hint ('Not checked in the blueprint: ' + $blueprintNotChecked[$type])))
        }
    }

    # 2. Index both sides by match key; unkeyed records become findings here.
    $blueprintIndex = Get-PERecordIndex -Records $blueprintRecordsCompared -SkipTypes $skipTypes -Side 'Blueprint' -Findings $findings
    $targetIndex = Get-PERecordIndex -Records $targetRecordsCompared -SkipTypes $skipTypes -Side 'Target' -Findings $findings

    # 3. Ambiguous, Changed, and Missing/TargetOnly candidates (grouped by lower-cased type for rename matching).
    $missingByType = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $targetOnlyByType = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $typesWithPaths = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $builtInTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@((Get-PEBuiltInResource).Keys), [System.StringComparer]::OrdinalIgnoreCase)
    $blueprintExportedAt = Get-PEMetaValue -Meta $Blueprint.Meta -Name 'ExportedAt'
    $targetExportedAt = Get-PEMetaValue -Meta $Target.Meta -Name 'ExportedAt'

    # get_Keys(): a record key literally named Keys or Count would shadow the Dictionary members.
    foreach ($matchKey in $blueprintIndex.get_Keys())
    {
        $blueprintRecords = $blueprintIndex[$matchKey]
        $targetRecords = $null
        if ($targetIndex.ContainsKey($matchKey))
        {
            $targetRecords = $targetIndex[$matchKey]
        }
        $first = $blueprintRecords[0]
        $targetCount = if ($targetRecords) { $targetRecords.Count } else { 0 }

        if ($blueprintRecords.Count -gt 1 -or $targetCount -gt 1)
        {
            $findings.Add((New-PEFinding -Kind 'Ambiguous' -ResourceType $first.ResourceType -Key $first.Key -Workload (Get-PERecordWorkload -Record $first) -Hint "Key matches $($blueprintRecords.Count) blueprint and $targetCount target records" -BlueprintCount $blueprintRecords.Count -TargetCount $targetCount))
        }
        elseif ($targetCount -eq 1)
        {
            $other = $targetRecords[0]
            $blueprintBag = $first.Properties
            if ($blueprintBag -isnot [System.Collections.IDictionary])
            {
                $blueprintBag = Get-PEPropertyBag -Record $first
            }
            $targetBag = $other.Properties
            if ($targetBag -isnot [System.Collections.IDictionary])
            {
                $targetBag = Get-PEPropertyBag -Record $other
            }
            # Advanced-function calls are costly at ~8,000 pairs, so whether a type has paths is cached per call.
            $hasPaths = $false
            if (-not $typesWithPaths.TryGetValue([string]$first.ResourceType, [ref]$hasPaths))
            {
                $hasPaths = (Get-PEIgnoredPath -ResourceType ([string]$first.ResourceType)).Count -gt 0
                $typesWithPaths[[string]$first.ResourceType] = $hasPaths
            }
            if ($hasPaths)
            {
                # Dotted ignore paths, applied to both sides (stored blueprints may predate the entry).
                $blueprintBag = Remove-PEIgnoredPath -ResourceType ([string]$first.ResourceType) -Properties $blueprintBag -ExportedAt $blueprintExportedAt
                $targetBag = Remove-PEIgnoredPath -ResourceType ([string]$first.ResourceType) -Properties $targetBag -ExportedAt $targetExportedAt
            }
            if ($isCrossTenant)
            {
                $hasTenantBound = $false
                if (-not $tenantBoundTypes.TryGetValue([string]$first.ResourceType, [ref]$hasTenantBound))
                {
                    $hasTenantBound = (Get-PEIgnoredPath -ResourceType ([string]$first.ResourceType) -TenantBound).Count -gt 0
                    $tenantBoundTypes[[string]$first.ResourceType] = $hasTenantBound
                }
                if ($hasTenantBound)
                {
                    $blueprintBag = Remove-PEIgnoredPath -ResourceType ([string]$first.ResourceType) -Properties $blueprintBag -TenantBound
                    $targetBag = Remove-PEIgnoredPath -ResourceType ([string]$first.ResourceType) -Properties $targetBag -TenantBound
                }
            }
            # Built-in objects (Data\BuiltInResources.psd1): the properties Microsoft controls are not compared, on both sides.
            if ($builtInTypes.Contains([string]$first.ResourceType))
            {
                $blueprintBag = Remove-PEBuiltInProperty -ResourceType ([string]$first.ResourceType) -Properties $blueprintBag
                $targetBag = Remove-PEBuiltInProperty -ResourceType ([string]$first.ResourceType) -Properties $targetBag
            }
            $differences = Get-PEPropertyDifference $blueprintBag $targetBag
            if ($differences.Count -gt 0 -and $targetName)
            {
                $differences = Remove-PETenantNameDifference -Difference $differences -BlueprintName $blueprintName -TargetName $targetName
            }
            if ($differences.Count -gt 0)
            {
                $findings.Add((New-PEFinding -Kind 'Changed' -ResourceType $first.ResourceType -Key $first.Key -Workload (Get-PERecordWorkload -Record $first) -Differences $differences -BlueprintRecord $first -TargetRecord $other))
            }
        }
        else
        {
            $type = [string]$first.ResourceType
            if (-not $missingByType.ContainsKey($type))
            {
                $missingByType[$type] = [System.Collections.Generic.List[object]]::new()
            }
            $missingByType[$type].Add($first)
        }
    }

    foreach ($matchKey in $targetIndex.get_Keys())
    {
        if ($blueprintIndex.ContainsKey($matchKey))
        {
            continue
        }
        $targetRecords = $targetIndex[$matchKey]
        $first = $targetRecords[0]
        if ($targetRecords.Count -gt 1)
        {
            $findings.Add((New-PEFinding -Kind 'Ambiguous' -ResourceType $first.ResourceType -Key $first.Key -Workload (Get-PERecordWorkload -Record $first) -Hint "Key matches 0 blueprint and $($targetRecords.Count) target records" -BlueprintCount 0 -TargetCount $targetRecords.Count))
            continue
        }
        $type = [string]$first.ResourceType
        if (-not $targetOnlyByType.ContainsKey($type))
        {
            $targetOnlyByType[$type] = [System.Collections.Generic.List[object]]::new()
        }
        $targetOnlyByType[$type].Add($first)
    }

    # 4. Decisions (applied in step 6; Unmanaged keys are also needed by the rename check in step 5).
    $noiseByType = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unmanaged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $excludedHere = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($decision in @($Decisions))
    {
        if ($null -eq $decision -or [string]::IsNullOrWhiteSpace([string]$decision.ResourceType))
        {
            continue
        }
        $type = [string]$decision.ResourceType
        if ($decision.Kind -eq 'Noise' -and -not [string]::IsNullOrWhiteSpace([string]$decision.Property))
        {
            if (-not $noiseByType.ContainsKey($type))
            {
                $noiseByType[$type] = [System.Collections.Generic.List[object]]::new()
            }
            $noiseByType[$type].Add([pscustomobject]@{
                    Key      = [string]$decision.Key
                    Property = [string]$decision.Property
                    Value    = ConvertTo-PECanonicalValue $decision.Value
                })
        }
        elseif ($decision.Kind -eq 'Unmanaged' -and -not [string]::IsNullOrWhiteSpace([string]$decision.Key))
        {
            [void]$unmanaged.Add((Get-PEMatchKey -ResourceType $type -Key ([string]$decision.Key)))
            $decisionTenant = $(if ($decision.PSObject.Properties['Tenant']) { [string]$decision.Tenant } else { '' })
            if (-not [string]::IsNullOrWhiteSpace($decisionTenant) -and $decisionTenant -ine 'master')
            {
                [void]$excludedHere.Add((Get-PEMatchKey -ResourceType $type -Key ([string]$decision.Key)))
            }
        }
    }

    # Unmanaged TargetOnly records are known and deliberately kept: they are never rename candidates (as in the quick
    # scan), so marking a lookalike Unmanaged leaves the similar Missing record creatable. They stay TargetOnly.
    if ($unmanaged.Count -gt 0)
    {
        foreach ($type in @($targetOnlyByType.get_Keys()))
        {
            $kept = [System.Collections.Generic.List[object]]::new()
            foreach ($record in $targetOnlyByType[$type])
            {
                if ($unmanaged.Contains((Get-PEMatchKey -ResourceType $record.ResourceType -Key $record.Key)))
                {
                    $findings.Add((New-PEFinding -Kind 'TargetOnly' -ResourceType $record.ResourceType -Key $record.Key -Workload (Get-PERecordWorkload -Record $record) -TargetRecord $record))
                }
                else
                {
                    $kept.Add($record)
                }
            }
            if ($kept.Count -eq 0)
            {
                [void]$targetOnlyByType.Remove($type)
            }
            else
            {
                $targetOnlyByType[$type] = $kept
            }
        }
    }

    # 5. Rename detection per type, then the Missing / TargetOnly / PossibleRename findings.
    foreach ($type in $missingByType.get_Keys())
    {
        $missingList = $missingByType[$type]
        $missingHints = $null
        $skipped = $false
        if ($targetOnlyByType.ContainsKey($type))
        {
            $targetList = $targetOnlyByType[$type]
            $rename = Find-PERenameCandidate -Missing $missingList.ToArray() -TargetOnly $targetList.ToArray() -Threshold $RenameThreshold
            $missingHints = $rename.MissingHints
            $skipped = $rename.Skipped
            for ($j = 0; $j -lt $targetList.Count; $j++)
            {
                $record = $targetList[$j]
                $kind = if ($rename.TargetHints[$j]) { 'PossibleRename' } else { 'TargetOnly' }
                $hint = if ($skipped) { $script:PERenameSkippedHint } else { $rename.TargetHints[$j] }
                $findings.Add((New-PEFinding -Kind $kind -ResourceType $record.ResourceType -Key $record.Key -Workload (Get-PERecordWorkload -Record $record) -Hint $hint -TargetRecord $record))
            }
            [void]$targetOnlyByType.Remove($type)
        }
        for ($i = 0; $i -lt $missingList.Count; $i++)
        {
            $record = $missingList[$i]
            $kind = if ($missingHints -and $missingHints[$i]) { 'PossibleRename' } else { 'Missing' }
            $hint = if ($skipped) { $script:PERenameSkippedHint } elseif ($missingHints) { $missingHints[$i] } else { $null }
            $findings.Add((New-PEFinding -Kind $kind -ResourceType $record.ResourceType -Key $record.Key -Workload (Get-PERecordWorkload -Record $record) -Hint $hint -BlueprintRecord $record))
        }
    }
    # Types with TargetOnly records and no Missing record.
    foreach ($list in $targetOnlyByType.Values)
    {
        foreach ($record in $list)
        {
            $findings.Add((New-PEFinding -Kind 'TargetOnly' -ResourceType $record.ResourceType -Key $record.Key -Workload (Get-PERecordWorkload -Record $record) -TargetRecord $record))
        }
    }

    # 6. Apply the decisions.
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($finding in $findings)
    {
        if ($finding.Kind -eq 'Changed' -and $noiseByType.ContainsKey($finding.ResourceType))
        {
            $rules = $noiseByType[$finding.ResourceType]
            $kept = foreach ($difference in $finding.Differences)
            {
                # The rule value is matched against the TARGET value with the same canonical (case-sensitive) string
                # comparison as everything else, so a Noise rule for 'Public' does not hide 'public'. Open question:
                # whether DSC's own Test-TargetResource compares these strings case-insensitively; if it does,
                # case-only differences may deserve a case-insensitive Noise match.
                $targetCanon = ConvertTo-PECanonicalValue $difference.Target
                $isNoise = $false
                foreach ($rule in $rules)
                {
                    if ($rule.Property -ieq $difference.Property -and
                        ([string]::IsNullOrEmpty($rule.Key) -or $rule.Key -ieq $finding.Key) -and
                        $rule.Value -ceq $targetCanon)
                    {
                        $isNoise = $true
                        break
                    }
                }
                if (-not $isNoise)
                {
                    $difference
                }
            }
            $finding.Differences = @($kept)
            if ($finding.Differences.Count -eq 0)
            {
                continue
            }
        }
        # Unmanaged covers only objects that exist in the target and not in the blueprint.
        $isTargetSide = $finding.Kind -eq 'TargetOnly' -or ($finding.Kind -eq 'PossibleRename' -and $null -ne $finding.TargetRecord)
        if ($isTargetSide -and $null -ne $finding.Key -and $unmanaged.Contains((Get-PEMatchKey -ResourceType $finding.ResourceType -Key $finding.Key)))
        {
            $finding.State = 'Unmanaged'
        }
        elseif ($finding.Kind -in 'Missing', 'Changed' -and $null -ne $finding.Key -and $excludedHere.Contains((Get-PEMatchKey -ResourceType $finding.ResourceType -Key $finding.Key)))
        {
            $finding.State = 'Unmanaged'
        }
        $result.Add($finding)
    }

    $result | Sort-Object -Property ResourceType, Key, Kind
}
