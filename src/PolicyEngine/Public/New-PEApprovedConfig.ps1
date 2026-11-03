function New-PEApprovedConfig
{
    <#
    .SYNOPSIS
    Builds the DSC configuration for an approved list: exactly the approved items, one configuration per resource type and phase.

    .DESCRIPTION
    The PreProd export (source) is compared with the Dev export (target) by Invoke-PEExportComparison, with the list's ExcludedProperties as
    in-memory PropertyExcluded decisions, so an Update keeps Dev's value for them. Each approved item is then looked at as Dev is now and
    ends in exactly one outcome (the list is re-runnable: an item that is already done is not an error):
      ToApply           it is still to be done: a configuration is generated for it (ResourceId is its DSC instance, for example
                        [AADGroup]AADGroup-Finance, as the LCM reports it)
      NoActionRequired  Dev already has the approved outcome (a Create that exists and matches, an Update that now matches, a Remove that is gone)
      Skipped           Dev is in a state the approval did not expect (a Create that exists but differs, an Update whose object has gone,
                        a Remove of something PreProd also has, a finding that is not a plain Missing / Changed / TargetOnly)
      NotGenerated      the engine refused to plan or generate it (its message is the Reason)
    ('Applied' and 'Failed' are decided later, by the LCM.) Nothing outside the list is ever planned. Configurations are ordered for applying:
    all Changes (types in dependency order from Sort-PERevertEntry), then all Removals.
    Returns [pscustomobject]@{ Items; Configs }. Items has one row per approved item in the order of the list:
    Action, ResourceType, Key, Outcome, Reason, ResourceId, ConfigurationName (the configuration that holds it, for ToApply). Configs: @{ ResourceType; Phase = Changes|Removals; ConfigurationName
    (PE_<Type>_<Phase>); Text; ItemCount }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        # The object Read-PEApprovedList / New-PEApprovedList returns.
        [Parameter(Mandatory)]
        [object]$List,

        [Parameter(Mandatory)]
        [string]$SourceExportPath,

        [Parameter(Mandatory)]
        [string]$TargetExportPath,

        [Parameter(Mandatory)]
        [string]$TargetTenantDomain,

        [Parameter(Mandatory)]
        [string]$DataRoot,

        # Workload prefixes whose Dev export is complete (an empty type there is really empty, so what PreProd has of it is Missing).
        [string[]]$CompleteWorkload = @('AAD', 'Intune', 'EXO', 'Teams')
    )

    $decisions = @(foreach ($item in @($List.Items))
        {
            foreach ($property in @($item.ExcludedProperties | Where-Object { $_ }))
            {
                [pscustomobject]@{ Kind = 'PropertyExcluded'; Tenant = 'target'; ResourceType = [string]$item.ResourceType; Key = [string]$item.Key; Property = [string]$property }
            }
        })
    $comparison = Invoke-PEExportComparison -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath -TargetTenantDomain $TargetTenantDomain `
        -DataRoot $DataRoot -CompleteWorkload $CompleteWorkload -Decision $decisions -WarningAction SilentlyContinue
    $state = $comparison.Check.State
    $blueprint = $comparison.Blueprint

    # What Dev is like now: open findings by (type, key), the keys Dev has, the types the comparison did not look at.
    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    $findingsByKey = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new($comparer)
    $notCompared = [System.Collections.Generic.Dictionary[string, string]]::new($comparer)
    foreach ($finding in @($comparison.Findings | Where-Object { $_.State -eq 'Open' }))
    {
        if ([string]::IsNullOrEmpty([string]$finding.Key))
        {
            if ($finding.Kind -in 'NotChecked', 'NotAvailable', 'Excluded') { $notCompared[[string]$finding.ResourceType] = "type '$($finding.ResourceType)' was not compared: $($finding.Hint)" }
            continue
        }
        $id = "$($finding.ResourceType)|$($finding.Key)"
        if (-not $findingsByKey.ContainsKey($id)) { $findingsByKey[$id] = [System.Collections.Generic.List[object]]::new() }
        $findingsByKey[$id].Add($finding)
    }
    $inDev = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($record in @($state.Records)) { [void]$inDev.Add("$($record.ResourceType)|$($record.Key)") }
    $managedTypes = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($record in @($blueprint.Records)) { [void]$managedTypes.Add([string]$record.ResourceType) }

    $rows = [System.Collections.Generic.List[object]]::new()
    $toApply = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($List.Items))
    {
        $row = [pscustomobject][ordered]@{
            Action = [string]$item.Action; ResourceType = [string]$item.ResourceType; Key = [string]$item.Key
            Outcome = ''; Reason = ''; ResourceId = $null; ConfigurationName = $null
        }
        $rows.Add($row)
        $id = "$($row.ResourceType)|$($row.Key)"
        $present = $inDev.Contains($id)
        $found = if ($findingsByKey.ContainsKey($id)) { @($findingsByKey[$id]) } else { @() }
        $skip = { param ($why) $row.Outcome = 'Skipped'; $row.Reason = $why }
        $wanted = @{ Create = 'Missing'; Update = 'Changed'; Remove = 'TargetOnly' }[$row.Action]

        if ($found.Count -gt 1)
        {
            & $skip "the key matches $($found.Count) findings ($((@($found.Kind) | Sort-Object -Unique) -join ', ')); it cannot be told apart"
        }
        elseif ($found.Count -eq 1)
        {
            $finding = $found[0]
            if ($finding.Kind -eq $wanted)
            {
                if (-not [string]::IsNullOrEmpty([string]$finding.Hint)) { & $skip ([string]$finding.Hint) }
                elseif ($wanted -eq 'TargetOnly' -and -not $managedTypes.Contains($row.ResourceType)) { & $skip "type '$($row.ResourceType)' has no records in PreProd's export, so nothing says Dev should not have these" }
                else { $row.Outcome = 'ToApply'; $toApply.Add([pscustomobject]@{ Row = $row; Finding = $finding; Action = $row.Action }) }
            }
            elseif ($row.Action -eq 'Create' -and $finding.Kind -eq 'Changed') { & $skip 'it exists in Dev but differs from PreProd; approve an Update instead' }
            elseif ($row.Action -eq 'Update' -and $finding.Kind -eq 'Missing') { & $skip 'it no longer exists in Dev, so there is nothing to update; approve a Create instead' }
            elseif ($row.Action -eq 'Remove' -and $finding.Kind -eq 'Changed') { & $skip 'PreProd has it too, so it is not removed' }
            else { & $skip "the comparison now says $($finding.Kind): $($finding.Hint)" }
        }
        elseif ($notCompared.ContainsKey($row.ResourceType))
        {
            & $skip $notCompared[$row.ResourceType]
        }
        elseif ($row.Action -eq 'Remove')
        {
            if ($present) { & $skip 'PreProd has it too, so it is not removed' }
            else { $row.Outcome = 'NoActionRequired'; $row.Reason = 'already gone from Dev' }
        }
        elseif ($present)
        {
            $row.Outcome = 'NoActionRequired'
            $row.Reason = if ($row.Action -eq 'Create') { 'exists in Dev and matches PreProd' } else { 'Dev already matches PreProd' }
        }
        else
        {
            & $skip 'it is in neither export (Dev does not have it and PreProd does not either)'
        }
    }

    # Plan what is still to be done, per action, in groups.
    $entryOf = [System.Collections.Generic.Dictionary[object, object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    foreach ($entry in $toApply) { $entryOf[$entry.Finding] = $entry }
    $planned = [System.Collections.Generic.List[object]]::new()
    foreach ($action in 'Create', 'Update', 'Remove')
    {
        $group = @($toApply | Where-Object { $_.Action -eq $action })
        if ($group.Count -eq 0) { continue }
        $removeDecisions = @()
        if ($action -eq 'Remove')
        {
            $removeDecisions = @($group | ForEach-Object {
                    [pscustomobject]@{ Kind = 'Remove'; ResourceType = $_.Row.ResourceType; Key = $_.Row.Key; Property = $null; Value = $null; Reason = 'approved list (not stored)'; At = '2026-01-01T00:00:00.000Z' }
                })
        }
        $result = New-PERectifyPlanSafe -Finding @($group | ForEach-Object { $_.Finding }) -Action $action -Source $state -Blueprint $blueprint -Decision $removeDecisions
        foreach ($p in $result.Planned) { $entry = $entryOf[$p.Finding]; $entry | Add-Member -NotePropertyName Plan -NotePropertyValue $p.Plan; $planned.Add($entry) }
        foreach ($r in $result.Refused) { $row = $entryOf[$r.Finding].Row; $row.Outcome = 'NotGenerated'; $row.Reason = $r.Reason }
    }

    # One configuration per type and phase: dependency order inside (Sort-PERevertEntry), all Changes first, then all Removals.
    $ordered = @(if ($planned.Count) { Sort-PERevertEntry -Entry $planned.ToArray() })
    $groups = [System.Collections.Specialized.OrderedDictionary]::new()
    foreach ($phase in 'Changes', 'Removals')
    {
        foreach ($entry in @($ordered | Where-Object { ($_.Action -eq 'Remove') -eq ($phase -eq 'Removals') }))
        {
            $key = "$($entry.Row.ResourceType)|$phase"
            if (-not $groups.Contains($key)) { $groups[$key] = [System.Collections.Generic.List[object]]::new() }
            $groups[$key].Add($entry)
        }
    }
    $configs = [System.Collections.Generic.List[object]]::new()
    foreach ($key in @($groups.Keys))
    {
        $type, $phase = $key -split '\|'
        $name = "PE_${type}_${phase}"
        $entries = @($groups[$key])
        $safe = ConvertTo-PEDscConfigSafe -Entry $entries -ConfigurationName $name -Target Replica
        $refusedEntries = [System.Collections.Generic.HashSet[object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
        foreach ($refusal in @($safe.Refused)) { [void]$refusedEntries.Add($refusal.Entry); $refusal.Entry.Row.Outcome = 'NotGenerated'; $refusal.Entry.Row.Reason = $refusal.Reason }
        $accepted = @($entries | Where-Object { -not $refusedEntries.Contains($_) })
        if (-not $safe.Text) { continue }

        # The blocks come out in the order of the entries: the first line of a block names the instance the LCM will report.
        $parts = Split-PEDscConfigText -Text $safe.Text
        if ($null -ne $parts -and @($parts.Blocks).Count -eq $accepted.Count)
        {
            for ($i = 0; $i -lt $accepted.Count; $i++)
            {
                $m = [regex]::Match(@($parts.Blocks[$i] -split "`n")[0], '^\s*(\w+)\s+["'']([^"'']+)["'']')
                if ($m.Success) { $accepted[$i].Row.ResourceId = "[$($m.Groups[1].Value)]$($m.Groups[2].Value)" }
            }
        }
        foreach ($entry in $accepted) { $entry.Row.ConfigurationName = $name }
        $configs.Add([pscustomobject][ordered]@{ ResourceType = $type; Phase = $phase; ConfigurationName = $name; Text = $safe.Text; ItemCount = $accepted.Count })
    }

    [pscustomobject]@{ Items = $rows.ToArray(); Configs = $configs.ToArray() }
}
