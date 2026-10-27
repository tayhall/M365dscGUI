function Export-PEGuiData
{
    <#
    .SYNOPSIS
    Writes the view-model JSON files the web GUI reads (gui\README.md, GUI spec "Data the GUI reads") from the latest
    Full check, the blueprint and the decisions. Read-only towards tenants; never touches activity\ or requests\.

    .DESCRIPTION
    One tenant entry per registered tenant (Get-PETenant) from the latest Full check of that tenant; a tenant with no check
    yet is listed empty so it can be checked from the GUI. Per-type counts are worked out here from the blueprint records and the findings. Limits: the engine does not track when a finding was
    first seen, so firstSeen is the export time of the check; the blueprint change record has no source, so version 1
    is 'Initial' and every later version 'Accept'. Files are replaced atomically.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [string]$DataRoot,

        [string]$GuiRoot,

        # Kept for older callers; every registered tenant is exported.
        [string]$TenantSlug,

        # Overrides the display name of the master (the registry holds the names of the others).
        [string]$TenantDisplayName
    )

    $root = Get-PEDataRoot -Override $DataRoot
    if (-not $GuiRoot)
    {
        $GuiRoot = Join-Path $root 'gui'
    }
    $GuiRoot = [System.IO.Path]::GetFullPath($GuiRoot)

    $blueprint = Get-PEBlueprint -Name $BlueprintName -DataRoot $root

    $text = { param($value) if ($value -is [datetime]) { $value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } elseif ($null -eq $value) { $null } else { [string]$value } }

    $write = {
        param($relative, $object)
        $path = Join-Path $GuiRoot $relative
        $parent = Split-Path $path
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $object -Depth 20), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $path, $true)
    }

    # Blueprint versions with change records.
    $versionsOf = {
        param ($name)
        $blueprintDirectory = Get-PEBlueprintDirectory -Name $name -DataRoot $root
        $versionNumbers = @(Get-PEBlueprintVersionNumber -Directory $blueprintDirectory)
        $opFor = @{ Missing = 'Added'; TargetOnly = 'Removed'; Changed = 'Changed' }
        $versions = foreach ($number in $versionNumbers)
        {
            $record = Read-PEJson -Path (Join-Path $blueprintDirectory ('changes\v{0:D4}.json' -f $number))
            $changes = @()
            if ($null -ne $record)
            {
                $changes = @(foreach ($change in @($record.Changes))
                    {
                        if ($null -eq $change -or [string]::IsNullOrEmpty([string]$change.Key)) { continue }
                        [ordered]@{
                            op           = $(if ($opFor.ContainsKey([string]$change.Kind)) { $opFor[[string]$change.Kind] } else { [string]$change.Kind })
                            resourceType = [string]$change.ResourceType
                            key          = [string]$change.Key
                            itemId       = ConvertTo-PEGuiItemId -ResourceType ([string]$change.ResourceType) -Key ([string]$change.Key)
                        }
                    })
            }
            [ordered]@{
                version  = [int]$number
                at       = $(if ($record) { & $text $record.At } else { & $text (Read-PEJson -Path (Get-PEBlueprintVersionFile -Directory $blueprintDirectory -Version $number)).Meta.ExportedAt })
                source   = $(if ($number -eq 1) { 'Initial' } elseif ($record -and $record.PSObject.Properties['RestoredFrom'] -and $record.RestoredFrom) { 'Revert' } else { 'Accept' })
                revertTo = $(if ($record -and $record.PSObject.Properties['RestoredFrom'] -and $record.RestoredFrom) { [int]$record.RestoredFrom } else { $null })
                reason   = $(if ($record) { [string]$record.Reason } else { 'Initial blueprint' })
                changes  = $changes
            }
        }
        @($versions)
    }
    $versions = @(& $versionsOf $BlueprintName)
    & $write 'blueprint/versions.json' $versions

    $registered = @(Get-PETenant -DataRoot $root)
    $tenantEntries = [System.Collections.Generic.List[object]]::new()
    $unmanagedAll = [System.Collections.Generic.List[object]]::new()
    $summary = @{ Findings = 0; Items = 0; CheckId = $null }
    $driftKinds = 'Missing', 'Changed', 'TargetOnly', 'PossibleRename', 'Ambiguous'
    foreach ($tenant in $registered)
    {
        $slug = [string]$tenant.Slug
        # The blueprints this tenant follows (master blueprint first); the last one is its own and what its items and reverts use.
        $layerNames = @(Get-PETenantBlueprint -Tenant $slug -MasterBlueprint $BlueprintName -DataRoot $root)
        # The version history of each tenant blueprint (blueprint/<name>/versions.json), for the Blueprint page of a tenant that follows it.
        foreach ($layerName in @($layerNames | Where-Object { $_ -ne $BlueprintName }))
        {
            try { & $write "blueprint/$layerName/versions.json" @(& $versionsOf $layerName) }
            catch { Write-Warning "The versions of blueprint '$layerName' could not be read: $($_.Exception.Message)" }
        }
        $tenantBlueprint = $blueprint
        if ($layerNames[-1] -ne $BlueprintName)
        {
            try { $tenantBlueprint = Get-PEBlueprint -Name $layerNames[-1] -DataRoot $root }
            catch { Write-Warning "Blueprint '$($layerNames[-1])' of tenant '$slug' could not be read; showing it against '$BlueprintName'." }
        }
        $check = $null
        try { $check = Get-PECheck -Latest -Kind Full -Tenant $slug -DataRoot $root } catch { $check = $null }
        # A name someone chose (it differs from the tenant id the registry falls back to) wins over -TenantDisplayName.
        $renamed = $tenant.DisplayName -and $tenant.DisplayName -ne $tenant.TenantId -and $tenant.DisplayName -ne $slug
        $displayName = $(if ($TenantDisplayName -and $slug -eq 'master' -and -not $renamed) { $TenantDisplayName } elseif ($tenant.DisplayName) { [string]$tenant.DisplayName } else { $slug })
        if ($null -eq $check)
        {
            # A connected tenant that has not been checked yet: listed empty, so the GUI can offer to check it.
            & $write "tenants/$slug/findings.json" @()
            & $write "tenants/$slug/items.json" @()
            & $write "tenants/$slug/status.json" ([ordered]@{ tenantId = $slug; workloads = @() })
            $tenantEntries.Add([ordered]@{ tenantId = $slug; role = [string]$tenant.Role; displayName = $displayName; tenantDomain = [string]$tenant.TenantId; offline = [bool]$tenant.Offline; lastFullCheck = $null; snapshot = $null; scopes = @(); typeScopes = @(); layers = @(Get-PEGuiLayerView -Tenant $tenant -Check $null -LayerNames $layerNames -DataRoot $root | ForEach-Object { $_.Summary }) })
            continue
        }
        $decisions = @(Get-PEDecision -DataRoot $root -Tenant $slug)
        $exportedAt = & $text $check.State.Meta.ExportedAt
        if ($null -eq $summary.CheckId) { $summary.CheckId = $check.CheckId }
        # Findings.
        $converted = ConvertTo-PEGuiFindingList -Findings @($check.Findings) -Records @($check.State.Records) -NotChecked @($check.State.NotChecked) -ExportedAt $exportedAt
        $findings = $converted.Findings
        $renameTarget = $converted.RenameTarget
        & $write "tenants/$slug/findings.json" @($findings)
        # Drift against every layer; the rows of the layers above the tenant's own are written beside findings.json.
        $layerViews = @(Get-PEGuiLayerView -Tenant $tenant -Check $check -LayerNames $layerNames -DataRoot $root -ExportedAt $exportedAt)
        foreach ($view in $layerViews | Where-Object { -not $_.Summary.sameAsOwn -and $_.Summary.checked })
        {
            & $write "tenants/$slug/layers/$($view.Name)/findings.json" @($view.Rows)
        }
        # What promote up and update tenant blueprint would change; the dialogs preview from this.
        if ($layerNames.Count -ge 2)
        {
            $moves = Get-PEGuiMoveList -MasterBlueprint $layerNames[0] -OwnBlueprint $layerNames[-1] -DataRoot $root
            if ($moves) { & $write "tenants/$slug/moves.json" $moves }
        }

        # Items: every blueprint record plus every target record.
        $items = [ordered]@{}
        $blueprintByItem = @{}
        foreach ($record in @($tenantBlueprint.Records))
        {
            if ([string]::IsNullOrEmpty([string]$record.Key)) { continue }
            $itemId = ConvertTo-PEGuiItemId -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key)
            $blueprintByItem[$itemId] = $record
            $items[$itemId] = [ordered]@{ itemId = $itemId; resourceType = [string]$record.ResourceType; key = [string]$record.Key; workload = [string]$record.Workload; inBlueprint = $true }
        }
        $targetByItem = @{}
        foreach ($record in @($check.State.Records))
        {
            if ([string]::IsNullOrEmpty([string]$record.Key)) { continue }
            $itemId = ConvertTo-PEGuiItemId -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key)
            $targetByItem[$itemId] = $record
            if (-not $items.Contains($itemId))
            {
                $items[$itemId] = [ordered]@{ itemId = $itemId; resourceType = [string]$record.ResourceType; key = [string]$record.Key; workload = [string]$record.Workload; inBlueprint = $false }
            }
        }
        & $write "tenants/$slug/items.json" @($items.Values)

        $unreadableByItem = @{}
        foreach ($finding in $findings | Where-Object { $_.kind -eq 'Unreadable' -and $_.itemId })
        {
            $unreadableByItem[$finding.itemId] = @($finding.differences | ForEach-Object { $_.property })
        }
        # The configuration a Revert would run, per item (about 5 s once; the dialog shows exactly this).
        $revert = @{ Wrapper = $null; Items = @{} }
        try { $revert = Get-PEGuiRevertConfig -Check $check -Blueprint $tenantBlueprint }
        catch { Write-Warning "Revert previews not generated: $($_.Exception.Message)" }
        if ($revert.Wrapper) { & $write "tenants/$slug/revert-wrapper.json" $revert.Wrapper }

        # The blueprint side of each layer above the tenant's own, so the item page can show the layer being viewed. An item's
        # entry is written only where that layer differs from the tenant blueprint (null: the layer does not have the item); no
        # entry means the same as the tenant blueprint. An item only a higher layer has gets a file too, but no row in items.json.
        $layerSides = [ordered]@{}
        $layerOnly = [ordered]@{}
        foreach ($layerName in @($layerNames | Select-Object -First ($layerNames.Count - 1)))
        {
            try { $layerState = Get-PEBlueprint -Name $layerName -DataRoot $root } catch { continue }
            $byItem = @{}
            foreach ($record in @($layerState.Records))
            {
                if ([string]::IsNullOrEmpty([string]$record.Key)) { continue }
                $layerItemId = ConvertTo-PEGuiItemId -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key)
                $byItem[$layerItemId] = $record
                if (-not $items.Contains($layerItemId) -and -not $layerOnly.Contains($layerItemId)) { $layerOnly[$layerItemId] = [ordered]@{ resourceType = [string]$record.ResourceType; key = [string]$record.Key } }
            }
            $layerSides[$layerName] = $byItem
        }

        foreach ($itemId in @($items.Keys) + @($layerOnly.Keys))
        {
            $item = $(if ($items.Contains($itemId)) { $items[$itemId] } else { $layerOnly[$itemId] })
            $layerBlueprints = [ordered]@{}
            foreach ($layerName in $layerSides.Keys)
            {
                $layerRecord = $layerSides[$layerName][$itemId]
                $ownRecord = $blueprintByItem[$itemId]
                if ($null -eq $layerRecord -and $null -eq $ownRecord) { continue }
                if ($null -ne $layerRecord -and $null -ne $ownRecord -and (ConvertTo-PECanonicalValue $layerRecord.Properties) -ceq (ConvertTo-PECanonicalValue $ownRecord.Properties)) { continue }
                $layerBlueprints[$layerName] = $(if ($null -ne $layerRecord) { $layerRecord.Properties } else { $null })
            }
            $revertKey = "$($item.resourceType)|$($item.key)"
            $detail = [ordered]@{
                itemId     = $itemId
                resourceType = $item.resourceType
                key        = $item.key
                targetKey  = $(if ($renameTarget.ContainsKey($itemId)) { [string]$renameTarget[$itemId].Key } else { $item.key })
                blueprint  = $(if ($blueprintByItem.ContainsKey($itemId)) { $blueprintByItem[$itemId].Properties } else { $null })
                layerBlueprints = $layerBlueprints
                target     = $(if ($renameTarget.ContainsKey($itemId)) { $renameTarget[$itemId].Properties } elseif ($targetByItem.ContainsKey($itemId)) { $targetByItem[$itemId].Properties } else { $null })
                targetNote = $null
                unreadable = @($(if ($unreadableByItem.ContainsKey($itemId)) { $unreadableByItem[$itemId] }))
                revert     = $(if ($revert.Items.ContainsKey($revertKey)) { $revert.Items[$revertKey] } else { $null })
            }
            & $write "tenants/$slug/items/$itemId.json" $detail
        }

        # Status: per workload and type. Excluded and NotChecked types never count as aligned.
        $notCheckedByType = @{}
        foreach ($entry in @($check.State.NotChecked))
        {
            if ($null -ne $entry) { $notCheckedByType[[string]$entry.ResourceType] = [string]$entry.Reason }
        }
        foreach ($finding in $findings | Where-Object { $_.kind -in 'NotChecked', 'NotAvailable' })
        {
            if (-not $notCheckedByType.ContainsKey($finding.resourceType)) { $notCheckedByType[$finding.resourceType] = $finding.error }
        }
        $excludedTypes = @($findings | Where-Object { $_.kind -eq 'Excluded' } | ForEach-Object { $_.resourceType })
        $driftedItems = @{}
        foreach ($finding in $findings | Where-Object { $_.state -eq 'Open' -and $_.kind -in $driftKinds -and $_.itemId })
        {
            $driftedItems[$finding.itemId] = $true
        }
        $typeNames = @(@($items.Values | ForEach-Object { $_.resourceType }) + @($notCheckedByType.Keys) + $excludedTypes | Sort-Object -Unique)
        $workloadOf = @{}
        foreach ($item in $items.Values) { $workloadOf[$item.resourceType] = $item.workload }
        foreach ($finding in $findings) { if ($finding.workload) { $workloadOf[$finding.resourceType] = $finding.workload } }
        $rows = foreach ($type in $typeNames)
        {
            $typeItems = @($items.Values | Where-Object { $_.resourceType -eq $type })
            $managed = @($typeItems | Where-Object { $_.inBlueprint })
            $isExcluded = $excludedTypes -contains $type
            $isNotChecked = $notCheckedByType.ContainsKey($type)
            $drifted = @($managed | Where-Object { $driftedItems.ContainsKey($_.itemId) }).Count
            $status = $(if ($isExcluded) { 'Excluded' } elseif ($isNotChecked) { $(if (@($findings | Where-Object { $_.kind -eq 'NotAvailable' -and $_.resourceType -eq $type })) { 'NotAvailable' } else { 'NotChecked' }) } else { 'Checked' })
            [pscustomobject][ordered]@{
                workload     = $(if ($workloadOf.ContainsKey($type)) { $workloadOf[$type] } else { 'Other' })
                resourceType = $type
                items        = $typeItems.Count
                managed      = $(if ($isExcluded) { 0 } else { $managed.Count })
                aligned      = $(if ($isExcluded -or $isNotChecked) { 0 } else { [Math]::Max(0, $managed.Count - $drifted) })
                drifted      = $(if ($isExcluded -or $isNotChecked) { 0 } else { $drifted })
                excluded     = $(if ($isExcluded) { $managed.Count } else { @($findings | Where-Object { $_.state -eq 'Unmanaged' -and $_.resourceType -eq $type }).Count })
                status       = $status
                error        = $(if ($isNotChecked) { $notCheckedByType[$type] } else { $null })
            }
        }
        $workloadStatus = foreach ($group in ($rows | Group-Object workload))
        {
            $typeRows = @($group.Group)
            [ordered]@{
                workload        = $group.Name
                managed         = [int]($typeRows | Measure-Object managed -Sum).Sum
                aligned         = [int]($typeRows | Measure-Object aligned -Sum).Sum
                drifted         = [int]($typeRows | Measure-Object drifted -Sum).Sum
                excluded        = [int]($typeRows | Measure-Object excluded -Sum).Sum
                notChecked      = @($typeRows | Where-Object { $_.status -in 'NotChecked', 'NotAvailable' }).Count
                notCheckedTypes = @($typeRows | Where-Object { $_.status -in 'NotChecked', 'NotAvailable' } | ForEach-Object { $_.resourceType })
                types           = @($typeRows | ForEach-Object { $row = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { if ($p.Name -ne 'workload') { $row[$p.Name] = $p.Value } }; $row })
            }
        }
        & $write "tenants/$slug/status.json" ([ordered]@{ tenantId = $slug; workloads = @($workloadStatus) })

        # Exclusions.
        $unmanagedAll.AddRange([object[]]@(foreach ($decision in $decisions | Where-Object { $_.Kind -eq 'Unmanaged' })
        {
            [ordered]@{
                tenantId     = $slug
                itemId       = ConvertTo-PEGuiItemId -ResourceType ([string]$decision.ResourceType) -Key ([string]$decision.Key)
                resourceType = [string]$decision.ResourceType
                key          = [string]$decision.Key
                reason       = [string]$decision.Reason
                at           = & $text $decision.At
            }
        }))
        # Scopes: named slices checked on their own (Invoke-PEScopeCheck). Shown on the Overview with their last check and drift.
        $scopeChecks = $check.State.Meta.PSObject.Properties['ScopeChecks']
        $scopeEntries = @(foreach ($scope in @(Get-PEScope -DataRoot $root))
            {
                $lastChecked = $null
                if ($scopeChecks -and $scopeChecks.Value -and $scopeChecks.Value.PSObject.Properties[$scope.Name])
                {
                    $lastChecked = & $text $scopeChecks.Value.($scope.Name)
                }
                [ordered]@{
                    name        = $scope.Name
                    description = $scope.Description
                    types       = @($scope.Types)
                    keys        = @($scope.Keys)
                    items       = @(@($tenantBlueprint.Records) | Where-Object { Test-PEInScope -Scope $scope -ResourceType ([string]$_.ResourceType) -Key ([string]$_.Key) }).Count
                    drifted     = @($findings | Where-Object { $_.state -eq 'Open' -and $_.kind -in $driftKinds -and (Test-PEInScope -Scope $scope -ResourceType $_.resourceType -Key $_.key) }).Count
                    # The open drift the page can act on as a whole (Revert or Promote the scope): item ids of Missing, Changed and TargetOnly items.
                    driftItems  = @($findings | Where-Object { $_.state -eq 'Open' -and $_.kind -in 'Missing', 'Changed', 'TargetOnly' -and $_.itemId -and -not $_.revertBlocked -and (Test-PEInScope -Scope $scope -ResourceType $_.resourceType -Key $_.key) } | ForEach-Object { $_.itemId })
                    lastChecked = $lastChecked
                }
            })

        # Every resource type of the blueprint is a scope too: its items, drift and when it was last checked on its own.
        $typeScopes = @(foreach ($group in @($tenantBlueprint.Records) | Group-Object ResourceType | Sort-Object Name)
            {
                $type = [string]$group.Name
                $lastChecked = $null
                if ($scopeChecks -and $scopeChecks.Value -and $scopeChecks.Value.PSObject.Properties[$type])
                {
                    $lastChecked = & $text $scopeChecks.Value.$type
                }
                [ordered]@{
                    type        = $type
                    workload    = [string]($group.Group | Select-Object -First 1).Workload
                    items       = $group.Count
                    drifted     = @($findings | Where-Object { $_.state -eq 'Open' -and $_.kind -in $driftKinds -and $_.resourceType -eq $type }).Count
                    driftItems  = @($findings | Where-Object { $_.state -eq 'Open' -and $_.kind -in 'Missing', 'Changed', 'TargetOnly' -and $_.itemId -and -not $_.revertBlocked -and $_.resourceType -eq $type } | ForEach-Object { $_.itemId })
                    lastChecked = $lastChecked
                }
            })

        # Where the snapshot came from: an upload says so per workload (Meta.Workloads); a check read from the tenant has none
        # and counts as Live at its export time for every workload of its records.
        $meta = $check.State.Meta
        $metaWorkloads = $meta.PSObject.Properties['Workloads']
        $snapshotWorkloads = @(if ($metaWorkloads -and $metaWorkloads.Value)
            {
                foreach ($property in $metaWorkloads.Value.PSObject.Properties) { [ordered]@{ workload = [string]$property.Name; source = [string]$property.Value.Source; at = & $text $property.Value.At } }
            }
            else
            {
                foreach ($name in @(@($check.State.Records) | ForEach-Object { [string]$_.Workload } | Where-Object { $_ } | Sort-Object -Unique)) { [ordered]@{ workload = $name; source = 'Live'; at = $exportedAt } }
            })
        $snapshot = [ordered]@{ source = $(if ([string]$meta.Source -eq 'Uploaded') { 'Uploaded' } else { 'Live' }); at = $exportedAt; workloads = $snapshotWorkloads }
        $summary.Findings += $findings.Count
        $summary.Items += $items.Count
        $tenantEntries.Add([ordered]@{
                tenantId      = $slug
                role          = [string]$tenant.Role
                displayName   = $displayName
                tenantDomain  = [string]$tenant.TenantId
                offline       = [bool]$tenant.Offline
                crossTenant   = (Test-PECrossTenant -BlueprintTenantId ([string](Get-PEMetaValue -Meta $tenantBlueprint.Meta -Name 'TenantId')) -TargetTenantId ([string]$tenant.TenantId))
                lastFullCheck = $exportedAt
                scopes        = $scopeEntries
                typeScopes    = $typeScopes
                layers        = @($layerViews | ForEach-Object { $_.Summary })
                snapshot      = $snapshot
            })
    }
    if ($tenantEntries.Count -eq 0 -or @($tenantEntries | Where-Object { $_.lastFullCheck }).Count -eq 0)
    {
        throw 'No Full check found for any tenant: run a full check first.'
    }

    # Exclusions: the unmanaged items of every tenant, and the noise rules (which apply to every tenant).
    $noise = foreach ($decision in @(Get-PEDecision -Kind Noise -DataRoot $root))
    {
        [ordered]@{
            resourceType = [string]$decision.ResourceType
            property     = [string]$decision.Property
            value        = $decision.Value
            itemId       = $(if ($decision.Key) { ConvertTo-PEGuiItemId -ResourceType ([string]$decision.ResourceType) -Key ([string]$decision.Key) } else { $null })
            reason       = [string]$decision.Reason
            at           = & $text $decision.At
        }
    }
    # Properties not enforced in one tenant (the rule can cover one item or every item of the type).
    $propertyExclusions = foreach ($decision in @(Get-PEDecision -Kind PropertyExcluded -DataRoot $root))
    {
        [ordered]@{
            tenantId     = [string]$decision.Tenant
            resourceType = [string]$decision.ResourceType
            property     = [string]$decision.Property
            key          = $(if ($decision.Key) { [string]$decision.Key } else { $null })
            itemId       = $(if ($decision.Key) { ConvertTo-PEGuiItemId -ResourceType ([string]$decision.ResourceType) -Key ([string]$decision.Key) } else { $null })
            reason       = [string]$decision.Reason
            at           = & $text $decision.At
        }
    }
    & $write 'exclusions.json' ([ordered]@{ unmanaged = @($unmanagedAll); noise = @($noise); propertyExclusions = @($propertyExclusions) })
    # Index.
    $latest = $versions[-1]
    $workloadNames = @('Entra ID', 'Intune', 'Exchange Online', 'Teams', 'Security and Compliance', 'Other')
    $dsc = Get-PEModuleState -BlueprintName $BlueprintName -DataRoot $root
    $index = [ordered]@{
        dsc                    = [ordered]@{ pin = $dsc.Pin; blueprint = $dsc.BlueprintVersion; match = $dsc.Match }
        generatedAt            = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        fullCheckOverdueHours  = 36
        blueprint              = [ordered]@{ name = $BlueprintName; version = $latest.version; acceptedAt = $latest.at; source = $latest.source; reason = $latest.reason; sourceTenantId = [string](Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId') }
        workloads              = $workloadNames
        # The engine's workload rule (Data\Workloads.psd1: a resource name starts with the prefix), so the page can tell the
        # workload of any resource type, not only the ones gui\ResourceTypes.json describes.
        workloadPrefixes       = @(Get-PEWorkloadDefinition | ForEach-Object { [ordered]@{ prefix = [string]$_.Prefix; name = [string]$_.Name } })
        tenants                = @($tenantEntries)
    }
    & $write 'index.json' $index
    & $write 'tenant-setup.json' ([ordered]@{ script = (Get-PETenantSetupScript) })

    [pscustomobject]@{ GuiRoot = $GuiRoot; CheckId = $summary.CheckId; BlueprintVersion = $latest.version; Findings = $summary.Findings; Items = $summary.Items; Tenants = $tenantEntries.Count }
}
