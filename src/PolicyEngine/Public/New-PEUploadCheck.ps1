function New-PEUploadCheck
{
    <#
    .SYNOPSIS
    Turns uploaded DSC export files of an offline tenant into a Full check (checks\<CheckId>\result.json).

    .DESCRIPTION
    Nothing connects to the tenant: the files are the export. They must all have been exported with the pinned
    Microsoft365DSC (Assert-PEUploadVersion); one that was not stops everything before anything is stored. The files are staged
    as ONE export folder (exports\<CheckId>, no export.log), read like a Full check reads its export, and a resource instance
    that is in more than one file counts once (one record per type and key, the later one; Warnings names an instance name
    that is in more than one file).

    There is no export log, so what the upload does not hold cannot be judged. The workloads that have at least one record
    in the upload are the workloads it covers. "Blueprint type" means a type of any blueprint layer the tenant follows (and of
    -BlueprintName), because the GUI compares the state with each layer; a check compared with no blueprint marks none (it seeds
    the own blueprint, which keeps its NotChecked list). A blueprint type of a workload neither the upload nor
    the earlier check covers is NotChecked ('workload not uploaded'). A blueprint type of a covered workload with no records is
    NotChecked ('no records in the upload and no export log') unless its workload is named in -CompleteWorkload: that says the
    upload holds everything of the workload, so the type is empty and the blueprint's records of it become Missing.

    When the tenant already has a Full check, the workloads in the upload replace that check's records of those workloads and
    every other workload is kept (as Invoke-PEScopeCheck folds a slice); Meta.PatchedFrom names the check it was built from.
    A blueprint type of a kept workload that the earlier check did not read (not in its records, its NotChecked list or the
    blueprint version it was made against) is NotChecked ('not read by the earlier check').
    State.Meta.Workloads says, per workload, whether it was Uploaded or read Live and when (UTC). A check written by
    Invoke-PEFullCheck or Invoke-PEScopeCheck has no Workloads: every workload of it is Live at its Meta.ExportedAt.

    -BlueprintName defaults to the tenant's own (last) blueprint. A tenant with none yet gets a check with no findings and no
    blueprint name; its State can then start the tenant's own blueprint (Initialize-PETenantBlueprint -FromCheck).
    -TenantDomain is stored as the tenant's TenantId (domain translation of a cross-tenant comparison reads it from there).
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant,

        # Files shaped @{ Name; Text }.
        [Parameter(Mandatory)]
        [object[]]$File,

        [string]$TenantDomain,

        # Workloads whose upload is complete: a blueprint type of it with no records is empty in the tenant, not unknown.
        [string[]]$CompleteWorkload = @(),

        [string]$BlueprintName,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $tenantEntry = Get-PETenant -Slug $Tenant -DataRoot $root
    if (-not $tenantEntry.Offline)
    {
        throw "Tenant '$Tenant' is not offline, so files cannot be uploaded for it. Mark it offline first (Set-PETenant -Offline)."
    }
    $tenantId = if ($TenantDomain) { $TenantDomain } else { [string]$tenantEntry.TenantId }
    if (-not $tenantId)
    {
        throw "Tenant '$Tenant' has no tenant domain yet. Pass -TenantDomain (for example contoso.onmicrosoft.com)."
    }
    Assert-PEUploadVersion -File $File

    # The own blueprint is named after the tenant and is the last one it follows (Initialize-PETenantBlueprint); a tenant that
    # follows the master blueprint alone has none yet.
    if (-not $BlueprintName -and @($tenantEntry.Blueprints).Count -and @($tenantEntry.Blueprints)[-1] -ceq $Tenant) { $BlueprintName = $Tenant }
    $blueprint = if ($BlueprintName) { Get-PEBlueprint -Name $BlueprintName -DataRoot $root } else { $null }

    $base = $null
    try { $base = Get-PECheck -Latest -Kind Full -Tenant $Tenant -DataRoot $root }
    catch { if ($_.Exception.Message -notmatch '^No Full check found under ') { throw } }

    # CheckId: sortable UTC timestamp, later than the base check and free.
    $moment = [datetime]::UtcNow
    while (($base -and $moment.ToString('yyyyMMdd-HHmmss') -le [string]$base.CheckId) -or (Test-Path -LiteralPath (Join-Path $root ('checks\' + $moment.ToString('yyyyMMdd-HHmmss')))) -or (Test-Path -LiteralPath (Join-Path $root ('exports\' + $moment.ToString('yyyyMMdd-HHmmss')))))
    {
        $moment = $moment.AddSeconds(1)
    }
    $checkId = $moment.ToString('yyyyMMdd-HHmmss')
    # The age of an upload is the time it was uploaded (the GUI labels it Uploaded): the files do not say when they were exported.
    $uploadedAt = $moment.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $stagePath = Join-Path $root ('exports\' + $checkId)
    $written = $false

    try
    {
        $warnings = @(Write-PEUploadStage -File $File -Path $stagePath)
        $exportFile = Find-PEExportFile -Path $stagePath
        $all = @(Read-PEExport -Path $exportFile -TenantId $tenantId | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ -ExportedAt $uploadedAt })

        # One record per (ResourceType, Key); the last one wins.
        $byKey = [ordered]@{}
        foreach ($record in $all) { $byKey[("$($record.ResourceType)|$($record.Key)").ToLowerInvariant()] = $record }
        $records = @($byKey.Values)
        $uploaded = @($records | ForEach-Object { [string]$_.Workload } | Sort-Object -Unique)

        $unknown = @($CompleteWorkload | Where-Object { $_ -and $uploaded -notcontains $_ })
        if ($unknown)
        {
            throw "-CompleteWorkload names $($unknown -join ', '), which the upload holds no record of. Workloads in the upload: $($uploaded -join ', ')."
        }

        # The workloads of the earlier check, each with where it came from and when.
        $workloads = [ordered]@{}
        $keptRecords = @()
        $keptNotChecked = @()
        $baseTypes = @(@(if ($blueprint) { $blueprint.Records }) | ForEach-Object { [string]$_.ResourceType } | Sort-Object -Unique)
        # The types of every blueprint layer the tenant follows (master first, own last) and of the one compared with: the GUI
        # compares the same state with each layer, so what the upload cannot show must be NotChecked for all of them, not only for
        # the compared one. A layer that cannot be read is left out here; its own view says it could not be read. A check compared
        # with no blueprint marks nothing: it is the seed of the tenant's own blueprint, and Initialize-PETenantBlueprint -FromCheck
        # copies its NotChecked list into that blueprint, where it would hide those types for good.
        $layerTypes = [System.Collections.Generic.List[string]]::new()
        foreach ($name in @(if ($blueprint) { @($tenantEntry.Blueprints) + @($BlueprintName) | Where-Object { $_ } | Select-Object -Unique }))
        {
            $layer = if ($name -ceq $BlueprintName) { $blueprint } else { try { Get-PEBlueprint -Name $name -DataRoot $root } catch { $null } }
            foreach ($record in @(if ($layer) { $layer.Records })) { $layerTypes.Add([string]$record.ResourceType) }
        }
        $layerTypes = @($layerTypes | Sort-Object -Unique)
        # The types the earlier check read: its records, its NotChecked list and the types of the blueprint version it was made
        # against (a live check exports those; an upload marks those it cannot show NotChecked). A type of a workload kept from it
        # that it did not read is NotChecked, never Missing: an item later moved into a blueprint must not look absent.
        $baseRead = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($base)
        {
            foreach ($record in @($base.State.Records)) { [void]$baseRead.Add([string]$record.ResourceType) }
            foreach ($entry in @($base.State.NotChecked | Where-Object { $null -ne $_ })) { [void]$baseRead.Add([string]$entry.ResourceType) }
            if ($base.BlueprintName -and $base.PSObject.Properties['BlueprintVersion'] -and $null -ne $base.BlueprintVersion)
            {
                # A blueprint version that cannot be read adds nothing: its types then count as not read (NotChecked, the safe side).
                $baseBlueprint = try { Get-PEBlueprint -Name ([string]$base.BlueprintName) -Version ([string]$base.BlueprintVersion) -DataRoot $root } catch { $null }
                foreach ($record in @(if ($baseBlueprint) { $baseBlueprint.Records })) { [void]$baseRead.Add([string]$record.ResourceType) }
            }
        }
        if ($base)
        {
            $baseMeta = $base.State.Meta
            if ($baseMeta.PSObject.Properties['Workloads'] -and $null -ne $baseMeta.Workloads)
            {
                foreach ($property in $baseMeta.Workloads.PSObject.Properties) { $workloads[$property.Name] = [ordered]@{ Source = [string]$property.Value.Source; At = [string]$property.Value.At } }
            }
            else
            {
                $notCheckedTypes = @(@($base.State.NotChecked) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.ResourceType })
                $names = @(@($base.State.Records) | ForEach-Object { if ($_.Workload) { [string]$_.Workload } else { Get-PEWorkload -ResourceType ([string]$_.ResourceType) } }) +
                    @($baseTypes | Where-Object { $notCheckedTypes -notcontains $_ } | ForEach-Object { Get-PEWorkload -ResourceType $_ })
                foreach ($name in ($names | Sort-Object -Unique)) { $workloads[$name] = [ordered]@{ Source = 'Live'; At = [string]$baseMeta.ExportedAt } }
            }
            $keptRecords = @(@($base.State.Records) | Where-Object { $uploaded -notcontains $(if ($_.Workload) { [string]$_.Workload } else { Get-PEWorkload -ResourceType ([string]$_.ResourceType) }) })
            $keptNotChecked = @(@($base.State.NotChecked) | Where-Object { $null -ne $_ -and $uploaded -notcontains (Get-PEWorkload -ResourceType ([string]$_.ResourceType)) })
        }
        foreach ($name in $uploaded) { $workloads[$name] = [ordered]@{ Source = 'Uploaded'; At = $uploadedAt } }

        # What the upload cannot show: there is no export log to say a type was read and found empty.
        $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($record in @($keptRecords) + @($records)) { [void]$present.Add([string]$record.ResourceType) }
        $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $keptNotChecked) { [void]$listed.Add([string]$entry.ResourceType) }
        $notChecked = [System.Collections.Generic.List[object]]::new()
        foreach ($type in $layerTypes)
        {
            if ($present.Contains($type) -or $listed.Contains($type)) { continue }
            $workload = Get-PEWorkload -ResourceType $type
            if (-not $workloads.Contains($workload))
            {
                $notChecked.Add([pscustomobject]@{ ResourceType = $type; Reason = 'workload not uploaded' })
            }
            elseif ($uploaded -contains $workload)
            {
                if ($CompleteWorkload -notcontains $workload) { $notChecked.Add([pscustomobject]@{ ResourceType = $type; Reason = 'no records in the upload and no export log' }) }
            }
            elseif (-not $baseRead.Contains($type))
            {
                $notChecked.Add([pscustomobject]@{ ResourceType = $type; Reason = 'not read by the earlier check' })
            }
        }

        $meta = @{
            TenantId      = $tenantId
            ExportedAt    = $uploadedAt
            Source        = 'Uploaded'
            ModuleVersion = (Get-PEPinnedVersion -Name Microsoft365DSC)
            TenantSlug    = $Tenant
            Workloads     = $workloads
        }
        if ($base) { $meta['PatchedFrom'] = [string]$base.CheckId }
        $state = New-PEState -Records @(@($keptRecords) + @($records)) -NotChecked @(@($keptNotChecked) + @($notChecked)) -Meta $meta

        $findings = @()
        $blueprintTenantId = ''
        $blueprintVersion = $null
        if ($blueprint)
        {
            $decisions = @(Get-PEDecision -DataRoot $root -Tenant $Tenant)
            $findings = @(Compare-PEState -Blueprint $blueprint -Target $state -Decisions $decisions)
            $blueprintTenantId = [string](Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId')
            $blueprintVersion = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $BlueprintName -DataRoot $root))[-1]
        }

        $document = [ordered]@{
            CheckId           = $checkId
            Kind              = 'Full'
            TenantSlug        = $Tenant
            BlueprintName     = $(if ($blueprint) { $BlueprintName } else { $null })
            BlueprintTenantId = $blueprintTenantId
            CrossTenant       = $(if ($blueprint) { Test-PECrossTenant -BlueprintTenantId (Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId') -TargetTenantId $tenantId } else { $false })
            BlueprintVersion  = $blueprintVersion
            Path              = $stagePath
            LogWarnings       = @($warnings)
            Findings          = $findings
            State             = $state
        }
        Write-PEJsonNew -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document
        $written = $true

        if ($TenantDomain -and $TenantDomain -ne $tenantEntry.TenantId)
        {
            Set-PETenant -Slug $Tenant -TenantId $TenantDomain -DataRoot $root | Out-Null
        }
    }
    catch
    {
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
        # A check written before the failure (the tenant domain could not be stored) goes too: no check without its tenant id.
        if ($written) { Remove-Item -LiteralPath (Join-Path $root "checks\$checkId") -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }

    [pscustomobject]@{
        CheckId   = $checkId
        Findings  = $findings
        Warnings  = $warnings
        Workloads = $uploaded
    }
}
