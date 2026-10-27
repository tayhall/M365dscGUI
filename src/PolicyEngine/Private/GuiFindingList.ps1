function ConvertTo-PEGuiFindingList
{
    # Findings of one comparison as the rows the GUI reads (findings.json). A Possible rename is two findings; the pair
    # becomes one row. Returns Findings (the rows) and RenameTarget (itemId -> the tenant record a rename points at).
    [CmdletBinding()]
    param
    (
        [AllowNull()]
        [object[]]$Findings,

        [AllowNull()]
        [object[]]$Records,

        [AllowNull()]
        [object[]]$NotChecked,

        [string]$ExportedAt
    )

    $notCheckedReason = @{}
    foreach ($entry in @($NotChecked))
    {
        if ($null -ne $entry) { $notCheckedReason[[string]$entry.ResourceType] = [string]$entry.Reason }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    # A Possible rename is two findings (the missing blueprint item and the new tenant item). The GUI shows the pair as
    # one row, on the blueprint side, with the settings that differ between the two.
    $pairId = { param ($type, $key) ([string]$type + '|' + [string]$key).ToLowerInvariant() }
    $recordOf = @{}
    foreach ($record in @($Records)) { $recordOf[(& $pairId $record.ResourceType $record.Key)] = $record }
    $renameTarget = @{}
    $blueprintSide = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($finding in @($Findings) | Where-Object { $_.Kind -eq 'PossibleRename' -and $_.BlueprintRecord })
    {
        [void]$blueprintSide.Add((& $pairId $finding.ResourceType $finding.Key))
    }
    foreach ($finding in @($Findings))
    {
        $key = [string]$finding.Key
        if ($finding.Kind -eq 'PossibleRename' -and $finding.TargetRecord -and -not $finding.BlueprintRecord -and "$($finding.Hint)" -match '^Possible rename of (.+)$' -and $blueprintSide.Contains((& $pairId $finding.ResourceType $Matches[1])))
        {
            continue
        }
        $hasKey = -not [string]::IsNullOrEmpty($key)
        $itemId = $(if ($hasKey) { ConvertTo-PEGuiItemId -ResourceType ([string]$finding.ResourceType) -Key $key } else { $null })
        $hint = $(if ($finding.Hint) { [string]$finding.Hint } else { $null })
        $other = $(if ($hint -match '^Possible rename of (.+)$') { $Matches[1] } else { $null })
        $error = $null
        if (@('NotChecked', 'NotAvailable') -contains [string]$finding.Kind)
        {
            $error = $(if ($notCheckedReason.ContainsKey([string]$finding.ResourceType)) { $notCheckedReason[[string]$finding.ResourceType] } else { $hint })
        }
        elseif (@('Unkeyed', 'Unreadable', 'Excluded') -contains [string]$finding.Kind)
        {
            $error = $hint
        }
        $rows.Add([ordered]@{
                id           = $(if ($hasKey) { $itemId } else { "$($finding.ResourceType)~" })
                itemId       = $itemId
                revertBlocked = $(Get-PERevertBlock -ResourceType ([string]$finding.ResourceType))
                resourceType = [string]$finding.ResourceType
                key          = $(if ($hasKey) { $key } else { $null })
                workload     = [string]$finding.Workload
                kind         = [string]$finding.Kind
                state        = $(if ($finding.State) { [string]$finding.State } else { 'Open' })
                differences  = @(foreach ($difference in $(if ($finding.Kind -eq 'PossibleRename' -and $finding.BlueprintRecord -and $other -and $recordOf.ContainsKey((& $pairId $finding.ResourceType $other))) { $renameTarget[$itemId] = $recordOf[(& $pairId $finding.ResourceType $other)]; Compare-PEGuiProperty -Blueprint $finding.BlueprintRecord.Properties -Target $renameTarget[$itemId].Properties } else { @($finding.Differences) }))
                    {
                        if ($null -ne $difference) { [ordered]@{ property = [string]$difference.Property; blueprint = $difference.Blueprint; target = $difference.Target } }
                    })
                excludedDifferences = @(foreach ($difference in @($(if ($finding.PSObject.Properties['ExcludedDifferences']) { $finding.ExcludedDifferences }))) { if ($null -ne $difference) { [ordered]@{ property = [string]$difference.Property; blueprint = $difference.Blueprint; target = $difference.Target } } })
                hint         = $hint
                other        = $other
                error        = $error
                firstSeen    = $exportedAt
            })
    }
    [pscustomobject]@{ Findings = $rows; RenameTarget = $renameTarget }
}
